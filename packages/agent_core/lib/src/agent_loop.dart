import 'dart:async';

import 'cancellation.dart';
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
    this.preferredTier,
  });

  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;

  /// When non-null, overrides the router-computed tier for this turn so
  /// callers (team runner, subagent) can pin a per-role model tier instead
  /// of relying on text-based routing only.
  final int? preferredTier;
}

/// Observed execution of one tool call inside an agent turn. Args are
/// already sanitized by the loop's [ContentSanitizer] when one is wired.
class ToolCallTrace {
  const ToolCallTrace({
    required this.name,
    required this.args,
    required this.isError,
    required this.durationMs,
  });

  final String name;
  final Map<String, dynamic> args;
  final bool isError;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'name': name,
        'args': args,
        'is_error': isError,
        'duration_ms': durationMs,
      };
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
    this.isToolParallelSafe,
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
    this.onTextDelta,
  });

  final Router router;
  final ContextBuilder contextBuilder;
  final Compactor compactor;
  final PermissionGate gate;
  final ToolExecutor executor;
  final MemoryStore memory;
  final ReplyFn reply;
  final ConfirmFn? confirm;

  /// Invoked for every raw model text delta while streaming (P1-4). Callers
  /// that push progressive updates to chat platforms must sanitize each
  /// delta themselves; the final reply still passes through the normal
  /// output guard.
  final void Function(String delta)? onTextDelta;
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

  /// Marks a session after successful output from an external trust boundary.
  final void Function(String sessionId)? taintMark;

  /// Returns true only for tools explicitly audited for parallel execution.
  /// Null defaults every tool to serialized execution.
  final bool Function(ToolCall call)? isToolParallelSafe;

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

  /// Real telemetry of the tools executed in the most recent handle() call:
  /// sanitized args, error status, and wall-clock duration per call. Consumed
  /// by the self-learning loop so skills are synthesized from the actual
  /// trajectory instead of name-only placeholders.
  final List<ToolCallTrace> _lastToolTraces = [];
  List<ToolCallTrace> get lastToolCalls => List.unmodifiable(_lastToolTraces);

  /// Slugs of non-draft/non-retired skills whose use was recorded during the
  /// most recent handle() call. Consumed by hosts so user feedback 👍/👎 can
  /// be routed back to the exact skills involved in the turn.
  List<String> _lastSkillsUsed = const [];
  List<String> get lastSkillsUsed => _lastSkillsUsed;

  /// Total tokens reported by providers during the most recent handle() call.
  int get lastTokensUsed => _budget.tokensUsed;
  String? _lastAnswer;

  /// True only when the most recent handle() call completed without a
  /// provider/guardrail/budget failure and produced a final answer.
  bool _lastTurnSucceeded = false;
  bool get lastTurnSucceeded => _lastTurnSucceeded;

  /// Final answer text of the most recent handle() call, after output
  /// sanitization. Null when the turn failed or produced no answer.
  String? get lastAnswer => _lastAnswer;

  final _loopDetector = LoopDetector();
  final _budget = BudgetGuard();

  /// Cooperative cancellation token for the turn currently being handled.
  /// Hosts call [cancelTurn] (from a stop button, gateway command, or team
  /// orchestrator) to abandon the turn at the next iteration/tool boundary.
  CancellationToken? _turnCancel;

  /// Cancels the turn currently being handled by this loop, if any.
  void cancelTurn() => _turnCancel?.cancel();

  Future<void> handle(
    InboundMessage m,
    Session session, {
    CancellationToken? cancelToken,
  }) async {
    _lastToolNames.clear();
    executedToolNames.clear();
    _lastToolTraces.clear();
    _lastSkillsUsed = const [];
    _lastAnswer = null;
    _lastTurnSucceeded = false;
    final cancel = _turnCancel = cancelToken ?? CancellationToken();
    final trace = TraceContext();
    trace.span('start');

    late final RouteDecision route;
    try {
      route = await router.route(
        m.text,
        session,
        preferredTier: config.preferredTier,
      );
    } on NoHealthyProviderException {
      await reply(
        m,
        'Semua provider AI sedang tidak tersedia (circuit breaker terbuka). '
        'Periksa koneksi/kuota provider atau coba lagi setelah jeda pemulihan.',
      );
      return;
    }
    _lastRouteExplain = route.toJson();
    if (route.risk == 'critical') {
      router.releaseProbe(route.providerId);
      await reply(m, 'Permintaan ditolak oleh guardrail (risiko critical).');
      return;
    }
    late final AgentContext initialContext;
    try {
      initialContext = await contextBuilder.build(session, m, route);
    } catch (_) {
      router.releaseProbe(route.providerId);
      rethrow;
    }
    var ctx = initialContext;
    var activeLlm = route.llm;
    var activeProviderId =
        route.providerId.isEmpty ? route.llm.id : route.providerId;

    final sw = Stopwatch()..start();
    var success = true;
    var initialProviderAttempted = false;

    try {
      _budget.reset(
        maxIterations: config.maxIterations,
        maxTokens: config.maxTokensPerTask,
        maxWallClockSec: config.maxWallClockSec,
        maxToolCalls: config.maxToolCalls,
      );

      agentLoop:
      for (var i = 0; i < config.maxIterations; i++) {
        if (shouldStop?.call() == true) {
          await reply(m, 'Tugas dihentikan (stop).');
          success = false;
          break;
        }
        if (cancel.isCancelled) {
          success = false;
          break agentLoop;
        }
        if (_budget.exceeded) {
          await reply(m, 'Budget habis (${_budget.reason}). Berhenti.');
          success = false;
          break;
        }

        final callSw = Stopwatch()..start();
        initialProviderAttempted = true;
        var resp = await _safeCollect(() => activeLlm.chat(ctx.toRequest()));
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
            resp = await _safeCollect(() => activeLlm.chat(ctx.toRequest()));
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
        for (final received in resp.toolCalls) {
          // Normalize to a mutable args map: the approval path injects a
          // capability token into call.args, and provider models may emit
          // const (unmodifiable) maps.
          final call = ToolCall(
            id: received.id,
            name: received.name,
            args: Map<String, dynamic>.from(received.args),
          );
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
            // Copy the args instead of mutating them: a ToolCall may carry a
            // const (unmodifiable) map, which rejects remove() at runtime.
            final sanitizedArgs = Map<String, dynamic>.from(call.args)
              ..remove('_capability_id');
            allowed.add(
              ToolCall(id: call.id, name: call.name, args: sanitizedArgs),
            );
          } else {
            success = false;
            final result = ToolResult.denied(verdict);
            denied.add((call: call, result: result, verdict: verdict));
            audit?.call(call, verdict, result);
            metrics?.recordTool(error: true);
            ctx = ctx.withToolResult(call, result);
          }
        }

        // Execute allowed tools in parallel. The batch races the turn's
        // cancellation token: a cancelled turn stops waiting on tool results
        // (cooperative — long-running tools also observe the token via
        // ToolContext.cancelToken and should stop early on their own).
        final runner = ParallelToolRunner(executor);
        final executed = await cancel.guard(
          runner.runAll(
            allowed,
            ToolContext(
              session: session,
              workspacePath: workspacePath,
              cancelToken: cancel,
            ),
            parallel: allowed.length > 1,
            isParallelSafe: isToolParallelSafe,
          ),
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
          _lastToolTraces.add(
            ToolCallTrace(
              name: call.name,
              args: sanitizer?.sanitizeArgs(call.args) ??
                  Map<String, dynamic>.of(call.args),
              isError: result.isError,
              durationMs: result.durationMs ?? 0,
            ),
          );
          if (!result.isError && ToolTrust.isExternalTaintSource(call.name)) {
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

    } on OperationCancelledException {
      success = false;
      _lastAnswer = null;
      try {
        await reply(m, 'Turn dibatalkan atas permintaan.');
      } catch (_) {}
    } finally {
      // A route can reserve a half-open probe before execution begins. If the
      // loop exits before the first provider call (including an exception in
      // budget/stop handling), release it so the next request can probe.
      if (!initialProviderAttempted) router.releaseProbe(route.providerId);
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
    final usedSkills = <String>[];
    for (final skill in skillRegistry?.match(m.text) ?? const <Skill>[]) {
      if (skill.status != SkillStatus.draft && skill.status != SkillStatus.retired) {
        skillRegistry?.recordUse(skill.slug, success: success);
        usedSkills.add(skill.slug);
      }
    }
    _lastSkillsUsed = List.unmodifiable(usedSkills);
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

  Future<LlmResponse> _safeCollect(
    Stream<LlmEvent> Function() openStream,
  ) async {
    try {
      // Invoke inside try so a provider that throws synchronously while
      // creating its stream follows the same fallback path as async errors.
      return await _collect(openStream());
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
          onTextDelta?.call(delta);
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
