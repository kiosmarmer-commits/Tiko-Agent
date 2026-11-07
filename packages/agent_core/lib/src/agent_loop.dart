import 'dart:async';

import 'interfaces.dart';
import 'models.dart';
import 'context_builder.dart';
import 'compactor.dart';
import 'loop_detector.dart';
import 'budget_guard.dart';
import 'router.dart';
import 'metrics.dart';
import 'skills.dart';
import 'skill_synthesis.dart';
import 'plan_execute.dart';
import 'trajectory.dart';
import 'trace.dart';
import 'self_consistency.dart';
import 'parallel_tools.dart';

/// Configuration for the agent loop.
class AgentConfig {
  const AgentConfig({
    this.maxIterations = 12,
    this.maxTokensPerTask = 60000,
    this.maxWallClockSec = 300,
    this.maxToolCalls = 30,
  });

  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;
}

typedef ReplyFn = Future<void> Function(InboundMessage m, String text);
typedef ConfirmFn = Future<bool> Function(ToolCall call, Session session);

/// Core ReAct-style agent loop (ALG-01) with budget, loop detection, and permission gate.
class AgentLoop {
  AgentLoop({
    required this.router,
    required this.contextBuilder,
    required this.compactor,
    required this.gate,
    required this.executor,
    required this.memory,
    required this.reply,
    this.confirm,
    this.config = const AgentConfig(),
    this.workspacePath = '.',
    this.audit,
    this.skillRegistry,
    this.skillsDir = 'skills',
    this.metrics,
    this.taintMark,
    this.sanitizer,
    this.sessionStore,
    this.shouldStop,
    this.reflector,
    this.enableReflection = false,
    this.trajectory,
    this.enableSelfConsistency = false,
    this.selfConsistencySamples = 3,
    this.autoReflectOnTools = 3,
    this.synthLlm,
    this.skillEval = const SkillEvalConfig(),
  });

  final Router router;
  final ContextBuilder contextBuilder;
  final Compactor compactor;
  final PermissionGate gate;
  final ToolExecutor executor;
  final MemoryStore memory;
  final ReplyFn reply;
  final ConfirmFn? confirm;
  final AgentConfig config;
  final String workspacePath;
  final void Function(
    ToolCall call,
    PermissionResult verdict,
    ToolResult result,
  )?
  audit;
  final SkillRegistry? skillRegistry;
  final String skillsDir;
  final Metrics? metrics;

  /// Called when tool result is untrusted (web/mcp/http).
  final void Function(String sessionId)? taintMark;

  /// Redacts secrets / neutralises untrusted content at trust boundaries.
  final ContentSanitizer? sanitizer;

  /// Persists each finished turn so history survives restart.
  final SessionStore? sessionStore;
  final bool Function()? shouldStop;
  final Reflector? reflector;
  final bool enableReflection;
  final TrajectoryLogger? trajectory;
  final bool enableSelfConsistency;
  final int selfConsistencySamples;

  /// If >0 and tool count >= this, run reflection even without AGENT_REFLECT.
  final int autoReflectOnTools;

  /// FR-01: optional dedicated LLM used for skill-synthesis reflection.
  /// When null, successful turns are compiled with the heuristic fallback.
  final LlmProvider? synthLlm;

  /// FR-01: S_eval weights and threshold for auto skill drafting.
  final SkillEvalConfig skillEval;

  /// Explainability payload of the most recent routing decision.
  Map<String, dynamic>? _lastRouteExplain;
  Map<String, dynamic>? get lastRouteExplain => _lastRouteExplain;

  final List<String> _lastToolNames = [];
  /// Actual tools whose adapters ran in this loop (used by golden/e2e tests).
  final List<String> executedToolNames = [];
  String? _lastAnswer;

  /// True only when the most recent handle() call completed without a
  /// provider/guardrail/budget failure and produced a final answer.
  bool _lastTurnSucceeded = false;
  bool get lastTurnSucceeded => _lastTurnSucceeded;

  final _loopDetector = LoopDetector();
  final _budget = BudgetGuard();

  Future<void> handle(InboundMessage m, Session session) async {
    _lastToolNames.clear();
    executedToolNames.clear();
    _lastAnswer = null;
    _lastTurnSucceeded = false;
    final trace = TraceContext();
    trace.span('start');

    final route = await router.route(m.text, session);
    _lastRouteExplain = route.toJson();
    if (route.risk == 'critical') {
      await reply(m, 'Permintaan ditolak oleh guardrail (risiko critical).');
      return;
    }
    var ctx = await contextBuilder.build(session, m, route);
    var activeLlm = route.llm;
    var activeProviderId =
        route.providerId.isEmpty ? route.llm.id : route.providerId;

    _budget.reset(
      maxIterations: config.maxIterations,
      maxTokens: config.maxTokensPerTask,
      maxWallClockSec: config.maxWallClockSec,
      maxToolCalls: config.maxToolCalls,
    );

    final sw = Stopwatch()..start();
    var success = true;

    agentLoop:
    for (var i = 0; i < config.maxIterations; i++) {
      if (shouldStop?.call() == true) {
        await reply(m, 'Tugas dihentikan (stop).');
        success = false;
        break;
      }
      if (_budget.exceeded) {
        await reply(m, 'Budget habis (${_budget.reason}). Berhenti.');
        success = false;
        break;
      }

      final callSw = Stopwatch()..start();
      var resp = await _safeCollect(activeLlm.chat(ctx.toRequest()));
      var isErr = resp.finishReason == 'error' ||
          (resp.text.contains('[error]') && resp.toolCalls.isEmpty);
      final attemptedProviders = <String>{activeProviderId};
      if (isErr) {
        router.recordFailure(activeProviderId, resp.text);
        // Walk the configured fallback chain, trying every eligible provider
        // at most once for this request. One failure must not be double-counted.
        while (isErr && attemptedProviders.length < router.providers.length) {
          final next = router.nextFallback(
            route,
            activeProviderId,
            exclude: attemptedProviders,
          );
          if (next == null) break;
          activeLlm = next;
          activeProviderId = next.id;
          attemptedProviders.add(activeProviderId);
          final fallbackSw = Stopwatch()..start();
          resp = await _safeCollect(activeLlm.chat(ctx.toRequest()));
          isErr = resp.finishReason == 'error' ||
              (resp.text.contains('[error]') && resp.toolCalls.isEmpty);
          if (isErr) {
            router.recordFailure(activeProviderId, resp.text);
          } else {
            router.recordSuccess(
              activeProviderId,
              fallbackSw.elapsedMilliseconds.toDouble(),
            );
          }
        }
      } else {
        router.recordSuccess(
          activeProviderId,
          callSw.elapsedMilliseconds.toDouble(),
        );
      }
      if (isErr) {
        success = false;
        await reply(m, 'Provider gagal merespons dan tidak ada fallback yang berhasil. Periksa konfigurasi atau koneksi provider.');
        break agentLoop;
      }
      _budget.addTokens(resp.usage);
      _budget.tickIteration();

      if (resp.toolCalls.isEmpty) {
        var ans = resp.text.isEmpty ? '(tidak ada jawaban)' : resp.text;
        if (ans == '(tidak ada jawaban)') success = false;
        ans = sanitizer?.output(ans) ?? ans;
        if (enableSelfConsistency) {
          try {
            final sc = SelfConsistency(
              activeLlm,
              samples: selfConsistencySamples,
            );
            final voted = await sc.answer(messages: ctx.messages);
            if (voted.trim().isNotEmpty) ans = voted.trim();
          } catch (_) {}
        }
        ans = sanitizer?.output(ans) ?? ans;
        _lastAnswer = ans;
        await reply(m, ans);
        break;
      }

      // Permission phase (sequential — may need user confirm)
      final allowed = <ToolCall>[];
      final denied =
          <({ToolCall call, ToolResult result, PermissionResult verdict})>[];
      for (final call in resp.toolCalls) {
        if (_budget.toolCallsExceeded) {
          await reply(m, 'Batas tool call tercapai. Berhenti.');
          success = false;
          break agentLoop;
        }
        var verdict = await gate.check(call, session);
        if (verdict.verdict == PermissionVerdict.needsConfirm) {
          final ok = confirm != null ? await confirm!(call, session) : false;
          if (!ok) {
            verdict = const PermissionResult(
              PermissionVerdict.denied,
              reason: 'user rejected',
            );
          } else {
            final again = await gate.check(call, session);
            verdict = again.verdict == PermissionVerdict.allowed
                ? again
                : PermissionResult(
                    PermissionVerdict.denied,
                    reason: again.reason ??
                        'approval could not be validated by the policy gate',
                  );
          }
        }
        if (verdict.verdict == PermissionVerdict.allowed) {
          // Capability is validated and consumed by the gate; it must not
          // reach tool adapters, tool output, or persisted execution traces.
          call.args.remove('_capability_id');
          allowed.add(call);
        } else {
          success = false;
          final result = ToolResult.denied(verdict);
          denied.add((call: call, result: result, verdict: verdict));
          audit?.call(call, verdict, result);
          metrics?.recordTool(error: true);
          ctx = ctx.withToolResult(call, result);
        }
      }

      // Execute allowed tools in parallel
      final runner = ParallelToolRunner(executor);
      final executed = await runner.runAll(
        allowed,
        ToolContext(session: session, workspacePath: workspacePath),
        parallel: allowed.length > 1,
      );
      for (final item in executed) {
        final call = item.call;
        final result = item.result;
        final verdict = const PermissionResult(PermissionVerdict.allowed);
        audit?.call(call, verdict, result);
        metrics?.recordTool(error: result.isError);
        if (result.isError) success = false;
        _lastToolNames.add(call.name);
        executedToolNames.add(call.name);
        if (!result.isError &&
            (call.name == 'web_fetch' ||
                call.name == 'web_search' ||
                call.name == 'http_request' ||
                call.name == 'read_file' ||
                call.name == 'list_dir' ||
                call.name == 'shell' ||
                call.name == 'patch_file' ||
                call.name.startsWith('mcp_') ||
                call.name.startsWith('script_'))) {
          taintMark?.call(session.id);
        }
        _budget.tickToolCall();
        final safeResult = sanitizer == null
            ? result
            : ToolResult(
                callId: result.callId,
                content: sanitizer!.toolResult(call, result.content),
                isError: result.isError,
                durationMs: result.durationMs,
              );
        ctx = ctx.withToolResult(call, safeResult);
        if (_loopDetector.isLooping(ctx.recentToolCalls)) {
          await reply(m, 'Loop terdeteksi (tool+args sama ≥3×). Berhenti.');
          success = false;
          break agentLoop;
        }
      }

      ctx = await compactor.maybeCompact(ctx);
    }

    // A run that exhausts its iteration budget without a final answer is
    // incomplete. Do not count it as a successful use of a skill.
    if (_lastAnswer == null) success = false;
    _lastTurnSucceeded = success;

    // optional reflection (ALG-03)
    final shouldReflect =
        reflector != null &&
        _lastAnswer != null &&
        (enableReflection ||
            (autoReflectOnTools > 0 &&
                _lastToolNames.length >= autoReflectOnTools));
    if (shouldReflect) {
      try {
        final r = await reflector!.reflect(
          goal: m.text,
          answer: _lastAnswer!,
          toolTrace: _lastToolNames,
        );
        if (r.revision != null && r.revision!.trim().isNotEmpty) {
          await reply(m, r.revision!);
          _lastAnswer = r.revision;
        }
      } catch (_) {}
    }

    final answer = _lastAnswer;
    if (answer != null) {
      try {
        await sessionStore?.appendTurn(
          session.id,
          user: m.text,
          assistant: answer,
          tools: List<String>.from(_lastToolNames),
        );
        await memory.addMessage(
          Message(sessionId: session.id, role: 'user', content: m.text),
        );
        await memory.addMessage(
          Message(sessionId: session.id, role: 'assistant', content: answer),
        );
      } catch (_) {
        // persistence is best-effort; the answer was already delivered
      }
    }
    final explicitMemory = _explicitMemoryRequest(m.text);
    if (explicitMemory != null) {
      try {
        await memory.upsertFact(Fact(
          id: '',
          text: explicitMemory,
          kind: 'preference',
          importance: 0.8,
          sourceSession: session.id,
          ownerKey: session.userKey,
          createdAt: DateTime.now().toUtc(),
          provenance: Provenance.user,
          confidence: 0.9,
          state: 'active',
        ));
      } catch (_) {
        // A memory failure must not invalidate an already delivered answer.
      }
    }
    await memory.afterTurn(session);
    for (final skill in skillRegistry?.match(m.text) ?? const <Skill>[]) {
      if (skill.status != SkillStatus.draft && skill.status != SkillStatus.retired) {
        skillRegistry?.recordUse(skill.slug, success: success);
      }
    }
    // FR-01 (closed-loop self-learning): compile a successful multi-tool
    // turn into a reusable SKILL.md draft when S_eval >= threshold.
    final registry = skillRegistry;
    if (registry != null) {
      final sEval = SkillSynthesis.evalScore(
        success: success,
        toolCalls: _lastToolNames.toSet().length,
        tokensUsed: _budget.tokensUsed,
        config: skillEval,
      );
      if (sEval >= skillEval.threshold) {
        try {
          final knownTools = {for (final s in ctx.tools) s.name};
          Skill? skill;
          final synth = synthLlm;
          if (synth != null) {
            skill = await SkillSynthesis.synthesizeDraft(
              llm: synth,
              goal: m.text,
              outcome: _lastAnswer ?? '',
              tools: _lastToolNames.toSet().toList(),
              skillsDir: skillsDir,
              knownTools: knownTools,
            );
          }
          skill ??= await SkillSynthesis.naiveDraft(
            goal: m.text,
            tools: _lastToolNames.toSet().toList(),
            skillsDir: skillsDir,
            knownTools: knownTools,
          );
          if (skill != null) {
            skill.status = SkillStatus.draft;
            registry.register(skill);
          }
        } catch (_) {
          // synthesis is best-effort; never fails the delivered answer
        }
      }
    }
    trace.span(success ? 'done' : 'fail');
    metrics?.recordTask(success: success, latencyMs: sw.elapsedMilliseconds);

    // ignore: discarded_futures
    trajectory?.logTurn(
      sessionId: session.id,
      input: sanitizer?.output(m.text) ?? m.text,
      output: sanitizer?.output(_lastAnswer ?? '') ?? (_lastAnswer ?? ''),
      tools: List.from(_lastToolNames),
      latencyMs: sw.elapsedMilliseconds,
      success: success,
    );
  }

  String? _explicitMemoryRequest(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > 300) return null;
    final lower = text.toLowerCase();
    final explicit = RegExp(
      r'^(?:tolong\s+)?(?:ingat(?:kan)?|simpan|catat|remember|please\s+remember)\b',
    ).hasMatch(lower);
    final identityOrPreference = RegExp(
      r'\b(?:nama saya|saya (?:lebih )?suka|saya tidak suka|preferensi saya)\b',
    ).hasMatch(lower);
    if (!explicit && !identityOrPreference) return null;
    return text;
  }

  Future<LlmResponse> _safeCollect(Stream<LlmEvent> events) async {
    try {
      return await _collect(events);
    } catch (_) {
      // A provider may throw while opening or streaming a response instead
      // of emitting LlmError. Normalize both paths into the same fail-closed
      // fallback flow without leaking exception details into the transcript.
      return LlmResponse(
        text: '[error] provider stream failed',
        finishReason: 'error',
      );
    }
  }

  Future<LlmResponse> _collect(Stream<LlmEvent> events) async {
    final resp = LlmResponse();
    final buf = StringBuffer();
    var hasError = false;
    await for (final e in events) {
      switch (e) {
        case LlmTextDelta(:final delta):
          buf.write(delta);
        case LlmToolCall(:final call):
          resp.toolCalls = [...resp.toolCalls, call];
        case LlmUsage(:final usage):
          resp.usage = usage;
        case LlmDone(:final finishReason):
          resp.finishReason = finishReason;
        case LlmError(:final message):
          hasError = true;
          buf.write('\n[error] $message');
      }
    }
    if (hasError) resp.finishReason = 'error';
    resp.text = buf.toString();
    return resp;
  }
}
