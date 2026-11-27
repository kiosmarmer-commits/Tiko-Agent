import 'dart:async';
import 'dart:io';

import 'cancellation.dart';
import 'compaction_events.dart';
import 'empty_response_guard.dart';
import 'repetition_guard.dart';
import 'error_classifier.dart';
import 'micro_compaction.dart';
import 'stream_max_lifetime.dart';
import 'interfaces.dart';
import 'models.dart';
import 'context_builder.dart';
import 'compactor.dart';
import 'checkpoints.dart';
import 'context_breakdown.dart';
import 'fast_mode.dart';
import 'image_token_cost.dart';
import 'image_eviction_policy.dart';
import 'message_sanitization.dart';
import 'turn_deadline.dart';
import 'loop_detector.dart';
import 'usage_anchor.dart';
import 'edit_loop_guard.dart';
import 'budget_guard.dart';
import 'router.dart';
import 'metrics.dart';
import 'skills.dart';
import 'preflight_gate.dart';
import 'skill_synthesis.dart';
import 'transcript_repair.dart';
import 'turn_liveness.dart';
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
    this.microCompaction = false,
    this.microCompactionKeepLastExchanges = 2,
    this.streamMaxLifetimeSec = 0,
    this.turnLivenessTimeoutSec = 600,
    this.preflightCompaction = true,
    this.imageEviction = false,
    this.retryWaitCapSec = 90,
    this.iterationWarnRatio,
    this.serviceTier,
    this.fastWindowSec = 60,
    this.reasoningEffort,
  });

  final int maxIterations;
  final int maxTokensPerTask;
  final int maxWallClockSec;
  final int maxToolCalls;

  /// Hermes micro-compaction (`agent/micro_compaction.py`): kompresi bergulir
  /// per-exchange di awal turn. OFF by default — tiap pass menulis ulang
  /// prefix prompt dan memutus provider prompt cache.
  final bool microCompaction;

  /// Exchange terakhir yang selalu tetap panas pada micro-compaction.
  final int microCompactionKeepLastExchanges;

  /// Hermes stream max-lifetime (`agent/stream_max_lifetime.py`): cap
  /// wall-clock total satu attempt stream dalam detik. 0 = off (default).
  final int streamMaxLifetimeSec;

  /// Hermes turn liveness (`agent/turn_liveness.py`): batas tanpa progres
  /// (bukan wall-clock total) dalam detik sebelum stream yang macet
  /// di-abort supaya sesi terbebas. Default 600s menyala seperti Hermes;
  /// 0 = off.
  final int turnLivenessTimeoutSec;

  /// Hermes preflight gate (`agent/turn_preflight_gate.py`): gerbang
  /// tekanan pra-API tiap iterasi — estimasi request penuh, kompresi
  /// preflight saat di atas ambang, blocker progres-tidak-cukup.
  final bool preflightCompaction;

  /// Hermes `evict_stale_outbound_tool_images` (send-path): eviksi gambar
  /// tool-result lama dari SALINAN request saat mendekati limit provider.
  /// Default off — gambar dipertahankan apa adanya bila tak perlu.
  final bool imageEviction;

  /// Hermes `free_tier_cooldown_ends_turn`: cooldown Retry-After (detik)
  /// di atas cap ini mengakhiri turn dengan pesan jelas alih-alih menunggu.
  final int retryWaitCapSec;

  /// Hermes `iteration_budget.py`: rasio (0,1) peringatan sisa iterasi;
  /// null = peringatan off.
  final double? iterationWarnRatio;

  /// Hermes fast mode (`agent/fast_mode.py`): tier default (`agent.
  /// service_tier`) — null = normal. Bounded window (`auto`/`cold`)
  /// diatur [fastWindowSec].
  final String? serviceTier;

  /// Panjang jendela fast bounded (`agent.fast_auto_seconds`, default 60).
  final int fastWindowSec;

  /// Hermes `reasoning_effort.py`: effort default (`agent.reasoning_effort`)
  /// — null = field reasoning TIDAK dikirim ke wire (deviasi sadar: Hermes
  /// menyuntik default medium pada sebagian profil; Tiko fail-open, unset
  /// tetap unset supaya prompt cache dan provider tak-sadari-reasoning
  /// tidak tersentuh).
  final String? reasoningEffort;


  /// When non-null, overrides the router-computed tier for this turn so
  /// callers (team runner, subagent) can pin a per-role model tier instead
  /// of relying on text-based routing only.
  final int? preferredTier;
}

/// Observed execution of one tool call inside an agent turn. Args are
/// already sanitized by the loop's [ContentSanitizer] when one is wired.
class ToolCallTrace {
  const ToolCallTrace({
    this.callId = '',
    required this.name,
    required this.args,
    required this.isError,
    required this.durationMs,
  });

  final String callId;
  final String name;
  final Map<String, dynamic> args;
  final bool isError;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        if (callId.isNotEmpty) 'call_id': callId,
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
    this.usageAnchorStore,
    this.imageTokenCosts,
    this.checkpointStore,
    this.fastMode,
    this.reasoningEffortOverride,
    this.synthLlm,
    this.onCompactionEvent,
    this.skillEval = const SkillEvalConfig(),
    this.editLoopVerify = false,
    this.onTextDelta,
    this.onToolCallStart,
    this.onToolTrace,
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

  /// C4 Chat-UX: dipanggil sebelum tiap tool dalam satu batch mulai dijalankan
  /// (nama saja, tanpa args). Pemanggil memakainya untuk status strip live;
  /// eksekusi paralel berarti urutan antar start tidak dijamin.
  final void Function(ToolCall call)? onToolCallStart;

  /// C4 Chat-UX: dipanggil setelah tiap tool selesai — trace berisi nama,
  /// args tersanitasi, status error, dan durasi. Kegagalan callback TIDAK
  /// diperbolehkan menghentikan turn (pemanggil wajib guard sendiri).
  final void Function(ToolCallTrace trace)? onToolTrace;

  /// Hermes usage anchor (C5): persistence anchor per sesi (null = anchor
  /// hanya hidup dalam turn). Direkomendasikan di host per-turn — tanpa ini
  /// anchor tidak bertahan lintas turn.
  final UsageAnchorStore? usageAnchorStore;

  /// Hermes image token cost (C7): tabel harga per-gambar yang dipelajari
  /// dari usage nyata provider (null = harga default flat, tanpa kalibrasi).
  final ImageTokenCostStore? imageTokenCosts;

  /// Hermes checkpoints (fase-10): snapshot file SEBELUM mutasi (write_file/
  /// patch_file) sehingga host bisa menyediakan `/undo`. Null = tanpa
  /// checkpoint (mutasi tetap berjalan, tanpa kemampuan undo).
  final CheckpointStore? checkpointStore;

  /// Hermes fast mode (fase-11, `agent/fast_mode.py`): state per sesi —
  /// tier + jendela bounded + model tanpa kapasitas fast. Null = fast mode
  /// off (request normal, tanpa service_tier).
  final FastModeState? fastMode;

  /// Hermes `reasoning_effort.py`: override effort per sesi (dari
  /// `/reasoning <level>`). Null → fallback [AgentConfig.reasoningEffort].
  final String? reasoningEffortOverride;

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

  /// Hermes compaction events: sink record `hermes.compaction` v1 dari
  /// micro-compaction dan kompresi batch/prune turn ini. Never-raises.
  final CompactionEventCallback? onCompactionEvent;

  /// FR-01: S_eval weights and threshold for auto skill drafting.
  final SkillEvalConfig skillEval;

  /// F2 (docs/15 §3) — edit-loop guard: bila aktif, setelah `patch_file`
  /// sukses seluruh tool lain ditahan hingga `verify_project` sukses.
  final bool editLoopVerify;

  /// Explainability payload of the most recent routing decision.
  Map<String, dynamic>? _lastRouteExplain;
  Map<String, dynamic>? get lastRouteExplain => _lastRouteExplain;

  /// Model yang dipilih router untuk turn terakhir (kosong bila tak
  /// diketahui) — dipakai host untuk estimasi biaya usage.
  String? _lastModelUsed;
  String? get lastModelUsed => _lastModelUsed;

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

  /// Hermes `iteration_budget.py`: observability budget iterasi turn
  /// terakhir untuk host (usage, peringatan mendekati cap).
  int get iterationsUsed => _budget.iterationsUsed;
  int get iterationsRemaining => _budget.iterationsRemaining;
  bool get iterationNearLimit => _budget.nearLimit;

  /// Total tokens reported by providers during the most recent handle() call.
  int get lastTokensUsed => _budget.tokensUsed;

  /// S20-C: rincian prompt tokens dilaporkan provider pada handle() terakhir.
  int get lastPromptTokens => _budget.promptTokens;

  /// S20-C: rincian completion tokens dilaporkan provider pada handle()
  /// terakhir.
  int get lastCompletionTokens => _budget.completionTokens;
  String? _lastAnswer;

  /// True only when the most recent handle() call completed without a
  /// provider/guardrail/budget failure and produced a final answer.
  bool _lastTurnSucceeded = false;
  bool get lastTurnSucceeded => _lastTurnSucceeded;

  /// Mesin sebab turn berakhir (Hermes `turn_explainers.py`): diisi pada
  /// setiap jalur keluar [handle] — 'completed', 'no_answer', 'stop_requested',
  /// 'cancelled', 'budget_exhausted', 'tool_call_limit', 'provider_error',
  /// 'loop_detected', 'iteration_limit', 'critical_risk', 'no_healthy_provider'.
  String? _lastTurnEndReason;

  /// Hermes error_classifier.py: klasifikasi granular kegagalan API
  /// terakhir turn ini (observability; null bila tidak ada kegagalan).
  ClassifiedError? _lastFailover;

  /// Alasan failover terakhir turn ini (null bila tidak ada error API).
  ClassifiedError? get lastFailover => _lastFailover;


  /// Hermes empty-response guard: deteksi jawaban kosong deterministik dan
  /// budget retry sadar-biaya, direset tiap jawaban non-kosong.
  final EmptyResponseGuard _emptyGuard = EmptyResponseGuard();

  /// Hermes micro-compaction (OFF by default — lihat [AgentConfig
  /// .microCompaction]): kompresi bergulir per-exchange sebelum turn
  /// dimulai. State ringkasan bertahan sepanjang umur loop instance.
  late final MicroCompactor _microCompactor = MicroCompactor(
    enabled: config.microCompaction,
    keepLastExchanges: config.microCompactionKeepLastExchanges,
    onCompactionEvent: onCompactionEvent,
  );
  MicroCompactionStats? get lastMicroCompaction => _microCompactor.last;

  /// Ringkasan bergulir micro-compaction untuk observability host.
  String get microRollingSummary => _microCompactor.rollingSummary;
  String? get lastTurnEndReason => _lastTurnEndReason;

  /// Penjelasan bahasa manusia untuk [lastTurnEndReason] — dipakai host
  /// untuk menjelaskan mengapa sebuah turn berakhir tanpa jawaban final.
  String? get lastTurnEndExplanation {
    switch (_lastTurnEndReason) {
      case 'completed':
        return 'Turn selesai dengan jawaban final.';
      case 'no_answer':
        return 'Model tidak menghasilkan jawaban; coba ulangi permintaan.';
      case 'stop_requested':
        return 'Turn dihentikan oleh sinyal stop host.';
      case 'cancelled':
        return 'Turn dibatalkan atas permintaan.';
      case 'budget_exhausted':
      case 'tool_call_limit':
      case 'iteration_limit':
        return 'Turn berakhir karena batas eksekusi tercapai '
            '($_lastTurnEndReason) sebelum jawaban final terbentuk.';
      case 'provider_error':
        return 'Semua provider gagal merespons; periksa konfigurasi/koneksi.';
      case 'loop_detected':
        return 'Turn dihentikan karena pola tool call berulang terdeteksi.';
      case 'critical_risk':
        return 'Permintaan ditolak guardrail (risiko critical).';
      case 'no_healthy_provider':
        return 'Tidak ada provider sehat (circuit breaker terbuka).';
      case 'billing_error':
        return 'Turn dihentikan: provider menolak karena billing/kuota.';
      default:
        return null;
    }
  }

  /// Path file yang berhasil ditulis turn ini (write_file/patch_file sukses).
  final Set<String> _fileMutationsOk = {};
  /// Path file yang seluruh percobaan penulisannya gagal pada turn ini.
  final Set<String> _fileMutationsFailed = {};

  /// Final answer text of the most recent handle() call, after output
  /// sanitization. Null when the turn failed or produced no answer.
  String? get lastAnswer => _lastAnswer;

  final _loopDetector = LoopDetector();
  final _budget = BudgetGuard();

  /// Hermes fase-23: deadline monotonik turn aktif (off bila budget 0).
  TurnDeadline _deadline = TurnDeadline.off();

  /// Hermes preflight gate: state per-turn, di-reset pada handle().
  PreflightGate? _preflight;

  /// Hermes usage anchor (C5): pengukuran nyata provider terakhir + posisi
  /// transcript yang dihargai; di-capture tiap respons dan dipersist per
  /// sesi via [usageAnchorStore]. Loop dibangun per-turn di host — anchor
  /// dipulihkan (dengan validasi fingerprint prefix) di request pertama.
  UsageAnchor? _usageAnchor;

  /// Harga token per-gambar terikat turn (C7): hasil kalibrasi runtime
  /// meng-override tabel yang dipelajari sampai turn berakhir.
  int? _imageCostOverride;

  /// Sesi yang sedang diproses (untuk persist/pulih anchor).
  String? _currentSessionId;

  /// Tekanan konteks ber-anchoring pass preflight TERAKHIR turn ini
  /// (null bila tidak pernah anchored). Getter host untuk observability.
  int? _lastAnchoredPressure;
  int? get lastAnchoredPressureTokens => _lastAnchoredPressure;

  /// Anchor usage aktif turn ini (null = belum ada / sudah kedaluwarsa).
  UsageAnchor? get usageAnchor => _usageAnchor;

  /// Hermes checkpoints (fase-10): snapshot file pre-mutasi turn berjalan
  /// (batch berurutan); host mendorongnya ke ledger per sesi untuk `/undo`.
  List<FileCheckpoint> _turnCheckpoints = const [];

  /// Hermes fase-11 fast mode: tier wire yang terlampir pada request
  /// terakhir + model tujuannya — dipakai untuk menandai model tanpa
  /// kapasitas fast saat rate limit menghantam request ber-tier.
  String? _fastTierAttached;
  String? _fastTierModel;
  List<FileCheckpoint> get lastTurnCheckpoints => _turnCheckpoints;

  /// Hermes context breakdown (fase-10): breakdown kategori konteks turn
  /// terakhir (system/tools/percakapan/gambar + occupancy anchored).
  ContextBreakdownResult? _lastContextBreakdown;
  ContextBreakdownResult? get lastContextBreakdown => _lastContextBreakdown;

  final _editGuard = EditLoopGuard();

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
    String? preferredProviderId,
    LlmProvider? preferredLlm,
  }) async {
    _lastToolNames.clear();
    executedToolNames.clear();
    _lastToolTraces.clear();
    _lastSkillsUsed = const [];
    _lastAnswer = null;
    _lastTurnSucceeded = false;
    _lastTurnEndReason = null;
    _fileMutationsOk.clear();
    _fileMutationsFailed.clear();
    _editGuard.reset();
    final cancel = _turnCancel = cancelToken ?? CancellationToken();
    final trace = TraceContext();
    trace.span('start');

    late final RouteDecision route;
    try {
      route = await router.route(
        m.text,
        session,
        preferredTier: config.preferredTier,
        preferredProviderId: preferredProviderId,
      );
    } on NoHealthyProviderException {
      _lastTurnEndReason = 'no_healthy_provider';
      await reply(
        m,
        'Semua provider AI sedang tidak tersedia (circuit breaker terbuka). '
        'Periksa koneksi/kuota provider atau coba lagi setelah jeda pemulihan.',
      );
      return;
    }
    _lastRouteExplain = route.toJson();
    final routeModel = route.model;
    if (routeModel != null && routeModel.isNotEmpty) {
      _lastModelUsed = routeModel;
    }
    if (route.risk == 'critical') {
      _lastTurnEndReason = 'critical_risk';
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
    var activeLlm = preferredLlm ?? route.llm;
    var activeProviderId =
        route.providerId.isEmpty ? route.llm.id : route.providerId;
    // Fase-10: pulihkan anchor tersimpan sejak awal turn (validasi prefix)
    // supaya breakdown konteks & preflight pertama sudah ber-anchoring.
    _usageAnchor ??= _restoreUsageAnchor(initialContext);
    try {
      _lastContextBreakdown = ContextBreakdown.compute(
        initialContext,
        anchor: _usageAnchor,
        imageCost: _boundImageCost(activeLlm),
      );
    } catch (_) {} // breakdown bukan keharusan turn
    if (config.microCompaction) {
      try {
        ctx = await _microCompactor.maybeMicroCompact(
          ctx,
          summarizer: synthLlm,
        );
      } catch (_) {} // fail-open: kompresi gagal ≠ turn gagal
    }

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
      _budget.warnRatio = config.iterationWarnRatio;
      // Hermes fase-23 (turn deadline monotonik): sisa-waktu turn dihitung
      // Stopwatch (bebas lompatan jam) dan dicek sebelum ronde tool baru.
      _deadline = config.maxWallClockSec > 0
          ? TurnDeadline(Duration(seconds: config.maxWallClockSec))
          : TurnDeadline.off();
      _preflight = PreflightGate(enabled: config.preflightCompaction);
      _currentSessionId = session.id;
      _imageCostOverride = null;
      _lastAnchoredPressure = null;
      _turnCheckpoints = const [];
      // Hermes fase-11 (fast_mode): buka (atau tolak) jendela fast di batas
      // user turn — `cold` hanya turn pertama tanpa riwayat pra-turn.
      _fastTierAttached = null;
      _fastTierModel = null;
      final fm = fastMode;
      if (fm != null) {
        fm.window = Duration(
          seconds: config.fastWindowSec > 0
              ? config.fastWindowSec
              : defaultFastWindowSec,
        );
        final msgs = initialContext.messages;
        final prior = (msgs.isNotEmpty && msgs.last.role == 'user')
            ? msgs.sublist(0, msgs.length - 1)
            : msgs;
        fm.beginTurn(prior);
      }

      agentLoop:
      for (var i = 0; i < config.maxIterations; i++) {
        if (shouldStop?.call() == true) {
          _lastTurnEndReason = 'stop_requested';
          await reply(m, 'Tugas dihentikan (stop).');
          success = false;
          break;
        }
        if (cancel.isCancelled) {
          _lastTurnEndReason = 'cancelled';
          success = false;
          try {
            await reply(m, 'Turn dibatalkan atas permintaan.');
          } catch (_) {} // best-effort
          break agentLoop;
        }
        if (_budget.exceeded) {
          _lastTurnEndReason = 'budget_exhausted';
          await reply(m, 'Budget habis (${_budget.reason}). Berhenti.');
          success = false;
          break;
        }

        final callSw = Stopwatch()..start();
        initialProviderAttempted = true;
        var resp = await _requestLlm(ctx, activeLlm);
        var isErr = resp.finishReason == 'error';
        final attemptedProviders = <String>{activeProviderId};
        if (isErr && resp.errorCode == llmErrorCodeTurnLiveness) {
          // Hermes turn_liveness: stream macet tanpa progres di-abort agar
          // sesi terbebas — TIDAK diikuti fallback chain (provider lain
          // besar kemungkinan macet dengan cara yang sama).
          _lastTurnEndReason = turnEndReasonLivenessAbort;
          success = false;
          try {
            await reply(
              m,
              turnLivenessAbortMessage(config.turnLivenessTimeoutSec),
            );
          } catch (_) {} // best-effort
          break agentLoop;
        }
        if (isErr) {
          // Klasifikasi + recovery chain satu kali di provider yang sama
          // (Hermes turn_recovery/turn_overflow): overflow → kompres konteks
          // lalu retry; rate limit → backoff lalu retry; billing → terminal.
          final err = ApiErrorClassifier.classify(
            code: resp.errorCode,
            message: resp.errorMessage ?? resp.text,
          );
          // Hermes error_classifier.py: taksonomi granular + recovery hints
          // untuk observability (additive — perilaku recovery existing
          // tidak berubah).
          _lastFailover = ApiErrorClassifierFailureTaxonomy.classifyFailure(
            code: resp.errorCode,
            message: resp.errorMessage ?? resp.text,
          );
          if (err.terminal) {
            _lastTurnEndReason = 'billing_error';
            success = false;
            await reply(
              m,
              'Permintaan ditolak provider (billing/kuota). '
              'Periksa langganan atau kuota akun, lalu coba lagi.',
            );
            break agentLoop;
          }
          if (err.retrySameProvider) {
            if (err.kind == ApiErrorKind.overflow) {
              try {
                ctx = await compactor.maybeCompact(
                  ctx,
                  llmOverride: activeLlm,
                  trigger: 'overflow',
                );
                ctx = compactor.pruneToolResults(ctx);
              } catch (_) {} // recovery best-effort
            } else {
              // Hermes free_tier_cooldown_ends_turn + retry_utils: cooldown
              // Retry-After di atas cap diakhiri dengan pesan jelas alih-
              // alih menunggu; di bawah cap → backoff singkat + cooldown
              // eksplisit supaya fallback chain melewatinya.
              final retryAfter =
                  ApiErrorClassifier.retryAfterSecondsFrom(
                code: resp.errorCode,
                message: resp.errorMessage ?? resp.text,
              );
              if (retryAfter != null &&
                  retryAfter > config.retryWaitCapSec) {
                router.setCooldown(
                  activeProviderId,
                  Duration(seconds: retryAfter),
                );
                _lastTurnEndReason = 'cooldown_ends_turn';
                success = false;
                try {
                  await reply(
                    m,
                    'Provider $activeProviderId kena rate limit dengan '
                    'cooldown ${retryAfter}s — menunggu tidak praktis, '
                    'turn diakhiri. Coba lagi nanti.',
                  );
                } catch (_) {} // best-effort
                break agentLoop;
              }
              await Future<void>.delayed(_rateLimitBackoff);
              router.setCooldown(
                activeProviderId,
                retryAfter != null
                    ? Duration(seconds: retryAfter)
                    : Duration(
                        milliseconds: _rateLimitBackoff.inMilliseconds),
              );
            }
            // Hermes fase-11 (mark_fast_mode_unavailable): 429 pada request
            // ber-tier fast → model ditandai tanpa kapasitas fast, retry
            // sekali di tier normal (deviasi: deteksi header limit=0 tidak
            // bisa di-port — provider Tiko tidak mengekspos header error).
            if (err.kind == ApiErrorKind.rateLimit &&
                _fastTierAttached != null) {
              fastMode?.markUnavailable(_fastTierModel);
            }
            resp = await _requestLlm(ctx, activeLlm);
            isErr = resp.finishReason == 'error';
          }
        }
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
            resp = await _requestLlm(ctx, activeLlm);
            isErr = resp.finishReason == 'error';
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
          _lastTurnEndReason = 'provider_error';
          success = false;
          await reply(m, 'Provider gagal merespons dan tidak ada fallback yang berhasil. Periksa konfigurasi atau koneksi provider.');
          break agentLoop;
        }
        _budget.addTokens(resp.usage);
        _budget.tickIteration();

        if (resp.toolCalls.isEmpty) {
          // Hermes empty-response guard: jawaban kosong tanpa penanda
          // (refusal yang diproxy) di-retry terbatas di provider yang sama
          // sebelum menyerah; dua kosong deterministik → langsung menyerah
          // (fallback chain tinggal satu langkah di turn berikutnya).
          if (resp.text.trim().isEmpty) {
            _recordEmptyAttempt(resp, activeProviderId);
            final budget = _emptyGuard.retryBudget();
            while (!_emptyGuard.deterministicEmpty &&
                _emptyGuard.attempts <= budget) {
              resp = await _requestLlm(ctx, activeLlm);
              if (resp.toolCalls.isNotEmpty || resp.text.trim().isNotEmpty) {
                break;
              }
              _recordEmptyAttempt(resp, activeProviderId);
            }
          } else {
            _emptyGuard.reset();
          }
          var ans = resp.text.trim().isEmpty
              ? '(tidak ada jawaban)'
              : resp.text;
          _lastTurnEndReason =
              resp.text.trim().isEmpty ? 'no_answer' : 'completed';
          if (ans == '(tidak ada jawaban)') {
            success = false;
            _emptyGuard.reset();
          }
          ans = sanitizer?.output(ans) ?? ans;
          // Hermes turn-explainer (footer verifikasi mutasi): beri tahu model
          // dan user ketika mutasi file yang diklaim tidak benar-benar terjadi
          // di disk. Best-effort — footer tidak pernah menggagalkan jawaban.
          ans = _withMutationFooter(ans);
          if (enableSelfConsistency) {
            try {
              final sc = SelfConsistency(
                activeLlm,
                samples: selfConsistencySamples,
              );
              final voted = await sc.answer(messages: ctx.messages);
              if (voted.trim().isNotEmpty) ans = voted.trim();
            } catch (_) {} // best-effort
          }
          ans = sanitizer?.output(ans) ?? ans;
          // Hermes repetition guard: jawaban final yang degenerate menjadi
          // loop repetisi runaway tidak dikirim apa adanya — user menerima
          // penjelasan potongan yang jelas, bukan 60k karakter echo. Watch
          // stream juga menandai finishReason 'repetition_loop' saat loop
          // terdeteksi selesai streaming.
          if (resp.finishReason == 'repetition_loop' ||
              (ans.length >= stopPathMinChars && isRunawayRepetition(ans))) {
            ans = repetitionLoopInterrupted;
            success = false;
            _lastTurnEndReason = 'repetition_loop';
          }
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
          if (_deadline.isExpired) {
            _lastTurnEndReason = 'deadline';
            await reply(m, 'Batas waktu turn tercapai. Berhenti.');
            success = false;
            break agentLoop;
          }
          if (_budget.toolCallsExceeded) {
            _lastTurnEndReason = 'tool_call_limit';
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
          if (editLoopVerify &&
              verdict.verdict == PermissionVerdict.allowed &&
              _editGuard.intercept(call) != null) {
            // F2 edit-loop guard: tool lain ditahan sebelum eksekusi; model
            // menerima hasil error dan dapat memulihkan dengan verify_project.
            final result = _editGuard.intercept(call)!;
            denied.add(
              (
                call: call,
                result: result,
                verdict: const PermissionResult(
                  PermissionVerdict.denied,
                  reason: 'edit-loop guard menunggu verify_project',
                ),
              ),
            );
            audit?.call(
              call,
              const PermissionResult(
                PermissionVerdict.denied,
                reason: 'edit-loop guard menunggu verify_project',
              ),
              result,
            );
            metrics?.recordTool(error: true);
            ctx = ctx.withToolResult(call, result);
          } else if (verdict.verdict == PermissionVerdict.allowed) {
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
        for (final call in allowed) {
          onToolCallStart?.call(call);
        }
        // Hermes checkpoints (fase-10): snapshot file pre-mutasi SEBELUM
        // eksekusi batch — /undo memulihkan keadaan pra-turn. Fail-open:
        // snapshot gagal tidak pernah memblokir tool.
        final cpStore = checkpointStore;
        if (cpStore != null && allowed.isNotEmpty) {
          try {
            final batch = cpStore.snapshotBatch(
              workspacePath,
              [
                for (final call in allowed)
                  if (_mutationToolNames.contains(call.name))
                    (
                      call.name,
                      call.args['path'] is String
                          ? call.args['path'] as String
                          : null,
                    ),
              ],
            );
            if (batch.isNotEmpty) {
              _turnCheckpoints = [..._turnCheckpoints, ...batch];
            }
          } catch (_) {}
        }
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
          if (editLoopVerify) _editGuard.observe(call.name, result.isError);
          if (result.isError) success = false;
          _lastToolNames.add(call.name);
          executedToolNames.add(call.name);
          final trace = ToolCallTrace(
            callId: call.id,
            name: call.name,
            args: sanitizer?.sanitizeArgs(call.args) ??
                Map<String, dynamic>.of(call.args),
            isError: result.isError,
            durationMs: result.durationMs ?? 0,
          );
          _lastToolTraces.add(trace);
          onToolTrace?.call(trace);
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
          _recordFileMutation(call, result);
          if (_loopDetector.isLooping(ctx.recentToolCalls)) {
            _lastTurnEndReason = 'loop_detected';
            await reply(m, 'Loop terdeteksi (tool+args sama ≥3×). Berhenti.');
            success = false;
            break agentLoop;
          }
        }

        // Kompresi konteks memakai LLM aktif turn ini sebagai peringkas
        // (fallback heuristic naive bila call gagal) sehingga sesi panjang
        // tidak pernah membawa transkrip penuh ke provider berikutnya.
        ctx = await compactor.maybeCompact(ctx, llmOverride: activeLlm);
        // Proactive tool-result prune (Hermes): hasil tool lama yang besar
        // diganti stub tanpa LLM — jauh lebih murah daripada kompresi penuh.
        ctx = compactor.pruneToolResults(ctx);
      }

      // Loop for selesai tanpa jawaban final (iterasi habis).
      if (_lastAnswer == null && _lastTurnEndReason == null) {
        _lastTurnEndReason = 'iteration_limit';
      }

    } on OperationCancelledException {
      success = false;
      _lastAnswer = null;
      _lastTurnEndReason ??= 'cancelled';
      try {
        await reply(m, 'Turn dibatalkan atas permintaan.');
      } catch (_) {} // best-effort
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
      } catch (e) {
        stderr.writeln('agent_loop: refleksi/revision gagal: $e');
      }
    }

    final answer = _lastAnswer;
    if (answer != null) {
      try {
        await sessionStore?.appendTurn(
          session.id,
          user: m.text,
          assistant: answer,
          tools: List<String>.from(_lastToolNames),
          provider: activeProviderId,
          model: _modelFor(route, activeLlm),
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

    // Hermes S6: simpan status turn terakhir + provider/model untuk indikator
    // dan filter history; kegagalan pencatatan tidak mengubah hasil turn.
    try {
      await sessionStore?.markTurnOutcome(
        session.id,
        ok: success,
        provider: activeProviderId,
        model: _modelFor(route, activeLlm),
      );
    } catch (_) {}

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

  /// Jeda tunggu sebelum retry provider yang sama setelah rate limit.
  static const _rateLimitBackoff = Duration(milliseconds: 800);

  /// Tools yang menulis/mengubah file di workspace (mutation tools).
  static const _mutationToolNames = {'write_file', 'patch_file'};

  void _recordFileMutation(ToolCall call, ToolResult result) {
    if (!_mutationToolNames.contains(call.name)) return;
    final path = call.args['path'];
    if (path is! String || path.trim().isEmpty) return;
    if (result.isError) {
      _fileMutationsFailed.add(path);
    } else {
      _fileMutationsOk.add(path);
      _fileMutationsFailed.remove(path);
    }
  }

  /// Footer verifikasi mutasi (Hermes `turn_explainers.py`): peringatkan
  /// bila jawaban mengklaim perubahan pada path yang seluruh percobaan
  /// penulisannya gagal, atau path yang diklaim tersimpan tidak ada di disk.
  /// Deterministik: hanya path yang benar-benar dicoba tool mutasi turn ini.
  String _withMutationFooter(String answer) {
    if (_fileMutationsOk.isEmpty && _fileMutationsFailed.isEmpty) {
      return answer;
    }
    final warnings = <String>[];
    for (final path in _fileMutationsFailed) {
      if (answer.contains(path)) {
        warnings.add(
          '- `$path` diklaim berubah tetapi seluruh percobaan penulisan '
          'pada turn ini gagal.',
        );
      }
    }
    for (final path in _fileMutationsOk) {
      if (!answer.contains(path)) continue;
      if (!_fileExistsInWorkspace(path)) {
        warnings.add(
          '- `$path` diklaim tersimpan tetapi tidak ditemukan di disk.',
        );
      }
    }
    if (warnings.isEmpty) return answer;
    var shown = warnings;
    var extra = 0;
    if (shown.length > 5) {
      extra = shown.length - 5;
      shown = shown.sublist(0, 5);
    }
    final suffix = extra > 0 ? '\n- ... dan $extra peringatan lainnya.' : '';
    return '$answer\n\n[verifikasi mutasi]\n'
        '${shown.join('\n')}$suffix';
  }

  bool _fileExistsInWorkspace(String relPath) {
    try {
      final p = relPath.trim();
      final f = File(p.startsWith('/') ? p : '$workspacePath/$p');
      return f.existsSync();
    } catch (_) {
      // Tidak bisa memverifikasi (mis. izin) — jangan false-positive.
      return true;
    }
  }

  String? _modelFor(RouteDecision route, LlmProvider llm) {
    return route.model ?? (llm.id == route.providerId ? null : llm.id);
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

  /// Catat satu jawaban kosong ke guard: bukti usage (nol output) atau
  /// konten teream. Harga tak dikenal → budget tetap default.
  void _recordEmptyAttempt(LlmResponse resp, String providerId) {
    final usagePresent = resp.usage.prompt > 0 || resp.usage.total > 0;
    _emptyGuard.recordAttempt(
      model: '',
      provider: providerId,
      finishReason: resp.finishReason,
      usagePresent: usagePresent,
      zeroOutput: usagePresent && resp.usage.completion == 0,
      observedGeneration: false,
    );
  }

  /// Hermes fase-8: satu panggilan request lengkap — gerbang preflight
  /// (kompresi pra-API saat tekanan di atas ambang) lalu perbaikan
  /// transcript (buang tool result/call yatim) sebelum request dikirim.
  /// Fase-9: gerbang preflight mendapat anchor usage (C5) dan harga
  /// per-gambar terikat turn (C7); setelah respons, usage nyata dicatat
  /// (re-anchor + kalibrasi gambar).
  Future<LlmResponse> _requestLlm(AgentContext ctx, LlmProvider llm) async {
    var useCtx = ctx;
    final preflight = _preflight;
    if (preflight != null) {
      // C5: pulihkan anchor tersimpan pada request pertama turn (validasi
      // fingerprint prefix; kedaluwarsa = dibuang, fail-closed).
      _usageAnchor ??= _restoreUsageAnchor(ctx);
      preflight.usageAnchor = _usageAnchor;
      preflight.imageTokenCost = _boundImageCost(llm);
      try {
        final verdict = await preflight.run(
          useCtx,
          compactor: compactor,
          llmOverride: llm,
        );
        useCtx = verdict.ctx;
        _lastAnchoredPressure = verdict.anchored ? verdict.pressure : null;
      } catch (_) {} // gerbang pra-API tidak boleh menggagalkan turn
    }
    if (config.imageEviction) {
      useCtx = _withImageEviction(useCtx);
    }
    final request = _withReasoningEffort(
      _withServiceTier(
        useCtx.toRequest(),
        _fastTierFor(llm.id),
      ),
    );
    final repaired = repairTranscript(sanitizeChatMessages(request.messages));
    final LlmResponse resp;
    if (repaired.length == request.messages.length) {
      resp = await _safeCollect(() => llm.chat(request));
    } else {
      resp = await _safeCollect(
        () => llm.chat(
          ChatRequest(
            messages: repaired,
            tools: request.tools,
            toolChoice: request.toolChoice,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            stream: request.stream,
            model: request.model,
            serviceTier: request.serviceTier,
            reasoningEffort: request.reasoningEffort,
          ),
        ),
      );
    }
    _observeUsage(repaired, resp, request.model ?? llm.id);
    return resp;
  }

  /// Pulihkan anchor tersimpan untuk sesi berjalan; hanya dihormati bila
  /// transcript masih membawa prefix yang dihargai (Hermes
  /// `restore_usage_anchor`); bila tidak, blob basah dibuang supaya tidak
  /// pernah menekan kompresi secara keliru.
  UsageAnchor? _restoreUsageAnchor(AgentContext ctx) {
    final store = usageAnchorStore;
    final sessionId = _currentSessionId;
    if (store == null || sessionId == null) return null;
    try {
      final anchor = store.load(sessionId);
      if (anchor == null) return null;
      if (anchor.matches(ctx.toRequest().messages)) return anchor;
      store.save(sessionId, null);
    } catch (_) {}
    return null;
  }

  /// Hermes fase-11 fast mode: tier wire efektif untuk [model] (null =
  /// normal), dan tempelkan ke request bila non-null.
  String? _fastTierFor(String? model) {
    final fm = fastMode;
    if (fm == null) return null;
    final tier = fm.effectiveServiceTier(model);
    if (tier != null) {
      _fastTierAttached = tier;
      _fastTierModel = model;
    }
    return tier;
  }

  /// Hermes fase-20 (`evict_stale_outbound_tool_images`): eviksi gambar
  /// tool-result lama dari salinan konteks per-request. Never-raises:
  /// kegagalan klasifikasi (header gambar tak terbaca) dihitung "tidak aman"
  /// oleh kebijakan, bukan error turn.
  AgentContext _withImageEviction(AgentContext ctx) {
    try {
      final r = evictStaleOutboundImages(ctx.messages);
      if (r.pruned == 0) return ctx;
      return AgentContext(
        messages: r.messages,
        tools: ctx.tools,
        session: ctx.session,
        systemPrompt: ctx.systemPrompt,
      )..recentToolCalls.addAll(ctx.recentToolCalls);
    } catch (_) {
      return ctx;
    }
  }

  ChatRequest _withServiceTier(ChatRequest r, String? tier) {
    if (tier == null || tier.isEmpty) return r;
    return ChatRequest(
      messages: r.messages,
      tools: r.tools,
      toolChoice: r.toolChoice,
      maxTokens: r.maxTokens,
      temperature: r.temperature,
      stream: r.stream,
      model: r.model,
      serviceTier: tier,
      reasoningEffort: r.reasoningEffort,
    );
  }

  /// Hermes `reasoning_effort.py`: effort efektif = override per-sesi
  /// (`/reasoning`) else default config; null/empty → request tak berubah
  /// (byte-identical, prompt cache aman).
  ChatRequest _withReasoningEffort(ChatRequest r) {
    final effort =
        (reasoningEffortOverride ?? config.reasoningEffort)?.trim() ?? '';
    if (effort.isEmpty) return r;
    return ChatRequest(
      messages: r.messages,
      tools: r.tools,
      toolChoice: r.toolChoice,
      maxTokens: r.maxTokens,
      temperature: r.temperature,
      stream: r.stream,
      model: r.model,
      serviceTier: r.serviceTier,
      reasoningEffort: effort,
    );
  }

  /// Harga token per-gambar efektif turn ini (C7): hasil kalibrasi runtime
  /// > tabel yang dipelajari > harga default flat.
  int _boundImageCost(LlmProvider llm) {
    if (_imageCostOverride != null) return _imageCostOverride!;
    return imageTokenCosts?.learnedFor(_lastModelUsed ?? llm.id) ??
        defaultImageTokenCost;
  }

  /// Hermes fase-9: setelah satu respons terhargai — (1) kalibrasi harga
  /// per-gambar dari residu (C7, memakai anchor SEBELUMNYA), lalu (2) re-
  /// anchor ke usage respons ini (C5). Usage tidak bisa dipakai → anchor
  /// lama dipertahankan (Hermes: caller keeps its anchor).
  void _observeUsage(List<ChatMessage> priced, LlmResponse resp, String model) {
    try {
      final usage = resp.usage;
      final pt = usage.prompt;
      if (pt <= 0) return;
      final store = imageTokenCosts;
      if (store != null) {
        final learned = store.calibrateFromUsage(
          model: model,
          promptTokens: pt,
          anchor: _usageAnchor,
          messages: priced,
        );
        if (learned != null) _imageCostOverride = learned;
      }
      final anchor = UsageAnchor.capture(pt, usage.completion, priced);
      if (anchor != null) {
        _usageAnchor = anchor;
        usageAnchorStore?.save(_currentSessionId ?? '', anchor);
      }
    } catch (_) {
      // Observability tidak boleh menggagalkan turn.
    }
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
    // Hermes stream watchdog (RunawayStreamWatch): kanal teks yang menjadi
    // loop repetisi runaway dihentikan sejak 16k char — delta berikutnya
    // tidak dikonsumsi lagi (stream di-cancel), output diganti pesan
    // interupsi yang jelas alih-alih 60k karakter echo.
    final watch = RunawayStreamWatch();
    var streamRunaway = false;
    // Hermes stream max-lifetime: cap wall-clock TOTAL satu attempt stream.
    // 0 = off (default); timer terpisah dari maxWallClockSec yang mencakup
    // seluruh turn termasuk eksekusi tool.
    final lifetime = config.streamMaxLifetimeSec > 0
        ? StreamLifetime(cap: config.streamMaxLifetimeSec.toDouble())
        : null;
    // Hermes turn liveness (B4): stream yang berhenti mengirim event tanpa
    // error > timeout di-abort (LlmError kode `turn_liveness`) supaya turn
    // tidak menggantung selamanya dan sesi terbebas.
    Stream<LlmEvent> source = events;
    if (config.turnLivenessTimeoutSec > 0) {
      final livenessTimeout =
          Duration(seconds: config.turnLivenessTimeoutSec);
      source = events.timeout(
        livenessTimeout,
        onTimeout: (sink) => sink.add(
          LlmError(
            turnLivenessAbortMessage(config.turnLivenessTimeoutSec),
            code: llmErrorCodeTurnLiveness,
          ),
        ),
      );
    }
    var livenessAbort = false;
    await for (final e in source) {
      if (streamRunaway) break;
      if (lifetime != null) {
        final exceeded = lifetime.exceeded(0);
        if (exceeded != null) {
          hasError = true;
          resp.finishReason = 'error';
          resp.errorMessage = streamLifetimeExceededMessage(exceeded, lifetime.cap);
          buf.write('\n[error] ${resp.errorMessage}');
          break;
        }
      }
      switch (e) {
        case LlmTextDelta(:final delta):
          if (watch.feed(delta)) {
            streamRunaway = true;
            continue;
          }
          buf.write(delta);
          onTextDelta?.call(delta);
        case LlmToolCall(:final call):
          resp.toolCalls = [...resp.toolCalls, call];
        case LlmUsage(:final usage):
          resp.usage = usage;
        case LlmDone(:final finishReason):
          resp.finishReason = finishReason;
        case LlmError(:final message, :final code):
          hasError = true;
          resp.errorCode = code;
          resp.errorMessage = message;
          buf.write('\n[error] $message');
          if (code == llmErrorCodeTurnLiveness) {
            livenessAbort = true;
          }
      }
      if (livenessAbort) break;
    }
    if (streamRunaway) {
      hasError = false;
      resp.finishReason = 'repetition_loop';
      resp.text = repetitionLoopInterrupted;
      return resp;
    }
    if (hasError) resp.finishReason = 'error';
    resp.text = buf.toString();
    return resp;
  }
}
