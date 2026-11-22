import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_security/agent_security.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;

import 'provider_factory.dart';
import 'smart_home_tool.dart';
import 'runtime_lock.dart';
import 'idle_consolidation.dart';
import 'context_refs.dart';
import 'attachment_ingest.dart';
import 'context_file.dart';
import 'event_hooks.dart';
import 'script_repair_advisor.dart';
import 'tiko_config.dart';
import 'capability.dart';
import 'event_bus.dart';
import 'approval_ledger.dart';
import 'resource_monitor.dart';
import 'offline_queue.dart';
import 'reflection_loop.dart';
import 'kanban_board.dart';
import 'self_learning_engine.dart';
import 'self_evolution.dart';
import 'memory_nudge.dart';
import 'turn_redirect.dart';
import 'bot_mode.dart';
import 'onboarding.dart';
import 'character_card.dart';
import 'team_tool.dart';

part 'tiko_runtime_internals.dart';
part 'code_loop.dart';
part 'bot_team.dart';
part 'research.dart';

const tikoVersion = '0.2.0';

enum CheckStatus { ok, warn, fail }

/// Result of one agent turn. Callers that schedule or queue work must inspect
/// [success] and retry failures instead of acknowledging any returned string.
class ChatRunResult {
  const ChatRunResult({
    required this.text,
    required this.success,
    this.retryable = false,
    this.tokensUsed = 0,
    this.toolCallCount = 0,
    this.toolCallTraces = const [],
    this.skillsUsed = const [],
  });
  final String text;
  final bool success;
  final bool retryable;

  /// Real token usage reported by providers during the turn.
  final int tokensUsed;

  /// Number of tool adapters that actually ran in the turn.
  final int toolCallCount;

  /// Per-call traces (sanitized args, error status, duration) of the turn.
  final List<ToolCallTrace> toolCallTraces;

  /// Slugs of skills whose use was recorded during the turn. Hosts route
  /// user feedback 👍/👎 back to these via SkillRegistry.applyFeedback.
  final List<String> skillsUsed;

  Map<String, dynamic> toJson() => {
        'text': text,
        'success': success,
        'retryable': retryable,
        'tokens_used': tokensUsed,
        'tool_call_count': toolCallCount,
        'skills_used': skillsUsed,
      };
}

/// One recorded tool step inside an inspected run (Run-inspector).
class RunStep {
  const RunStep({
    required this.tool,
    required this.verdict,
    required this.isError,
    required this.durationMs,
    required this.at,
  });
  final String tool;
  final String verdict;
  final bool isError;
  final int durationMs;
  final String at;

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'verdict': verdict,
        'is_error': isError,
        'duration_ms': durationMs,
        'at': at,
      };
}

/// Live/recent record of one agent turn (Run-inspector). Runs are kept in a
/// bounded in-memory ring — nothing here is a security decision; every field
/// is sanitized by the caller (same [SecuritySanitizer] used for chat).
class InspectedRun {
  InspectedRun({
    required this.id,
    required this.session,
    required this.channel,
    required this.input,
  })  : startedAt = DateTime.now().toUtc().toIso8601String(),
        subagent = session.contains('/sub/'),
        parent = session.contains('/sub/')
            ? session.substring(0, session.indexOf('/sub/'))
            : null;
  final String id;
  final String session;
  final String channel;
  final String input;
  final bool subagent;
  final String? parent;
  final String startedAt;
  String state = 'running';
  DateTime? endedAt;
  int? durationMs;
  bool? success;
  int tokensUsed = 0;
  int toolCalls = 0;
  String? answer;
  String? error;
  final List<RunStep> steps = [];

  Map<String, dynamic> toJson({bool includeSteps = true}) {
    return {
      'id': id,
      'session': session,
      'channel': channel,
      'subagent': subagent,
      'parent': parent,
      'input': input,
      'state': state,
      'started_at': startedAt,
      'ended_at': endedAt?.toIso8601String(),
      'duration_ms': durationMs,
      'success': success,
      'tokens_used': tokensUsed,
      'tool_calls': toolCalls,
      'answer': answer,
      'error': error,
      'steps': includeSteps
          ? steps.map((s) => s.toJson()).toList()
          : <Map<String, dynamic>>[],
    };
  }
}

/// Live turn registry backing the Run-inspector (GUI-P2-04). Purely
/// observational: begin/record/finish are called around each turn, never
/// influence the turn itself. Bounded memory: recent run ring + step cap.
class TurnInspector {
  static const int _maxRuns = 50;
  static const int _maxStepsPerRun = 100;
  final List<InspectedRun> _runs = [];
  int _seq = 0;

  InspectedRun begin({
    required String session,
    required String channel,
    required String input,
  }) {
    final entry = InspectedRun(
      id: 'run-${DateTime.now().microsecondsSinceEpoch}-${++_seq}',
      session: session,
      channel: channel,
      input: input,
    );
    _runs.add(entry);
    while (_runs.length > _maxRuns) {
      _runs.removeAt(0);
    }
    return entry;
  }

  /// Live tool step; matches by run id (unique per entry, even when several
  /// same-session runs nest via internal commands).
  void recordTool(
    String runId, {
    required String tool,
    required String verdict,
    required bool isError,
    required int durationMs,
  }) {
    final entry = _entry(runId);
    if (entry == null || entry.steps.length >= _maxStepsPerRun) return;
    entry.steps.add(RunStep(
      tool: tool,
      verdict: verdict,
      isError: isError,
      durationMs: durationMs,
      at: DateTime.now().toUtc().toIso8601String(),
    ));
  }

  void finish(
    String runId, {
    required bool success,
    required int tokensUsed,
    required int toolCalls,
    String? answer,
  }) {
    final entry = _entry(runId);
    if (entry == null || entry.state != 'running') return;
    entry
      ..state = 'done'
      ..endedAt = DateTime.now().toUtc()
      ..success = success
      ..tokensUsed = tokensUsed
      ..toolCalls = toolCalls
      ..answer = answer
      ..durationMs = entry.endedAt!.difference(DateTime.parse(entry.startedAt)).inMilliseconds;
  }

  void fail(String runId, {required String error}) {
    final entry = _entry(runId);
    if (entry == null || entry.state != 'running') return;
    entry
      ..state = 'error'
      ..endedAt = DateTime.now().toUtc()
      ..success = false
      ..error = error
      ..durationMs = entry.endedAt!.difference(DateTime.parse(entry.startedAt)).inMilliseconds;
  }

  InspectedRun? _entry(String runId) {
    for (var i = _runs.length - 1; i >= 0; i--) {
      if (_runs[i].id == runId) return _runs[i];
    }
    return null;
  }

  /// `{active: [...running], recent: [...done/error newest first],
  /// truncated}` — [maxRuns] caps each list.
  Map<String, dynamic> snapshot({int maxRuns = 40}) {
    final cap = maxRuns.clamp(1, _maxRuns);
    final active = <Map<String, dynamic>>[];
    final recent = <Map<String, dynamic>>[];
    for (final run in _runs.reversed) {
      if (run.state == 'running') {
        if (active.length < cap) active.add(run.toJson());
      } else if (recent.length < cap) {
        recent.add(run.toJson());
      }
    }
    return {
      'active': active,
      'recent': recent,
      'truncated': _runs.length >= _maxRuns,
    };
  }
}

class DoctorCheck {
  const DoctorCheck(this.name, this.status, this.detail);
  final String name;
  final CheckStatus status;
  final String detail;

  Map<String, dynamic> toJson() =>
      {'name': name, 'status': status.name, 'detail': detail};
}

/// Single composition root shared by CLI, daemon/API, Flutter and gateways
/// (PRD P0 #1). Everything stateful (sessions, memory, audit) lives here so
/// that every surface sees the same profile, sessions and providers.
class TikoRuntime {
  TikoRuntime._({
    required this.config,
    required this.issues,
    required this.providers,
    required this.registry,
    required this.sessions,
    required this.memory,
    required this.memoryBackend,
    required this.safety,
    required this.sandboxKind,
    required this.audit,
    required this.workspace,
    required this.dataDir,
    required this.skills,
    required this.skillsRoot,
    required this.goldenDir,
    required this.jobs,
    required this.mcpLoader,
    required this.scriptRunner,
    required this.evidence,
    required this.mcpEnvironment,
    required this.decision,
    required this.tirith,
    required this.capabilities,
    required this.credentialManager,
    required this.fallbackManager,
    required this.promptGuard,
    required this.anomalyDetector,
    required this.plugins,
    required this.layeredMemory,
    required this.curatedMemory,
    required this.memoryNudge,
    required this.turnRedirects,
    required this.botStore,
    required this.botTeamStore,
    required this.researchRunStore,
    required this.pluginConsents,
    required this.ragPipeline,
    this.reflectionEngine,
    this.personaPrompt,
    SelfLearningEngine? selfLearningEngine,
    SelfEvolutionEngine? selfEvolution,
    this.smartHomeTool,
    SandboxRunner? sandbox,
  }) : _sandbox = sandbox {
    _tokenAnomaly = config.tokenAnomaly.enabled
        ? TokenAnomalyDetector(
            minSamples: config.tokenAnomaly.minSamples,
            windowSize: config.tokenAnomaly.windowSize,
            zMultiplier: config.tokenAnomaly.zMultiplier,
            minSpikeRatio: config.tokenAnomaly.minSpikeRatio,
            cooldown: Duration(minutes: config.tokenAnomaly.cooldownMinutes),
          )
        : null;
    _idleConsolidator = config.idleConsolidation.enabled && providers.isNotEmpty
        ? IdleMemoryConsolidator(
            memory: layeredMemory,
            llm: auxiliaryLlm()!,
            config: IdleConsolidationConfig(
              enabled: true,
              idleTurns: config.idleConsolidation.idleTurns,
              minCandidates: config.idleConsolidation.minCandidates,
              maxEntriesPerBatch:
                  config.idleConsolidation.maxEntriesPerBatch,
              maxSummariesPerDay:
                  config.idleConsolidation.maxSummariesPerDay,
              maxRetention: config.idleConsolidation.maxRetention,
              maxOutputFacts: config.idleConsolidation.maxOutputFacts,
            ),
            onEvent: events.emit,
          )
        : null;
    this.selfLearningEngine = selfLearningEngine ??
        (providers.isEmpty
            ? null
            : SelfLearningEngine(
                llmProvider: auxiliaryLlm()!,
                skillRegistry: skills,
                memoryStore: memory,
                sessionStore: sessions,
                skillsDir: skillsRoot,
                config: const SelfLearningConfig(),
              ));
    this.selfEvolution = selfEvolution ??
        (providers.isEmpty
            ? null
            : SelfEvolutionEngine(
                dataDir: dataDir,
                llmProvider: auxiliaryLlm(),
                skills: skills,
                reflectionEngine: reflectionEngine,
                events: events,
              ));
  }

  final TikoConfig config;
  final List<ConfigIssue> issues;
  final Map<String, LlmProvider> providers;
  final ToolRegistry registry;
  final SessionStore sessions;
  final MemoryStore memory;
  final String memoryBackend;
  final SafetyState safety;
  final SandboxKind sandboxKind;

  /// The OS-sandbox runner shared by shell/script/MCP tools; kept so
  /// [close] can tear down a persistent docker container (P1-5).
  final SandboxRunner? _sandbox;
  final SmartHomeTool? smartHomeTool;
  final AuditLog audit;
  final String workspace;
  final String dataDir;
  final SkillRegistry skills;

  /// Skill yang dipakai turn terakhir per sesi (C1) — agar 👍/👎 tingkat
  /// turn bisa diarahkan ke skill yang tepat. In-memory, cap 500 sesi.
  final Map<String, List<String>> _sessionSkillsUsed = {};

  /// E1 (opt-in): detektor anomali token per skill. Null = nonaktif.
  TokenAnomalyDetector? _tokenAnomaly;

  /// E2 (opt-in): konsolidator memori idle. Null = nonaktif.
  IdleMemoryConsolidator? _idleConsolidator;

  /// E1: hitung karantina per UTC day (cap anti-spam penindakan).
  final Map<String, int> _tokenQuarantinesByDay = {};

  /// Counter turn yang diblokir/di-sanitasi PromptGuard (Security Center,
  /// GUI-P1-10) — in-memory, reset saat proses restart.
  int _guardBlockedTurns = 0;
  int _guardSanitizedTurns = 0;

  void _rememberSessionSkills(String sessionId, List<String> slugs) {
    _sessionSkillsUsed[sessionId] = List.of(slugs);
    while (_sessionSkillsUsed.length > 500) {
      _sessionSkillsUsed.remove(_sessionSkillsUsed.keys.first);
    }
  }

  /// Feedback tingkat turn (C1): mengarahkan 👍/👎 ke skill yang dipakai
  /// turn terakhir [sessionId] (metrik durabel via registry) dan ke ledger
  /// trajectory self-evolution. Mengembalikan slug skill yang dinilai
  /// (kosong bila sesi belum punya turn/skill aktif).
  Future<List<String>> applyTurnFeedback({
    required String sessionId,
    required bool positive,
    String actor = 'api',
  }) async {
    final slugs = _sessionSkillsUsed[sessionId] ?? const <String>[];
    for (final slug in slugs) {
      final s = skills.get(slug);
      if (s == null) continue;
      if (s.status == SkillStatus.draft || s.status == SkillStatus.retired) {
        continue;
      }
      skills.applyFeedback(slug, positive: positive);
    }
    await skills.flushPendingSinks();
    try {
      await selfEvolution?.recordFeedback(
        sessionId: sessionId,
        positive: positive,
      );
    } catch (_) {
      // Evolution feedback is best-effort; skill metrics above are durable.
    }
    try {
      await audit.log(
        sessionId: sessionId,
        tool: 'feedback',
        args: {'positive': positive, 'skills': slugs},
        risk: 'low',
        verdict: 'applied',
        resultSummary: 'actor=$actor skills=${slugs.join(',')}',
      );
    } catch (_) {}
    events.emit('feedback.turn', {
      'session': sessionId,
      'positive': positive,
      'skills': slugs,
      'actor': actor,
    });
    return List.of(slugs);
  }

  /// Muat ulang skill dari workspace `skills/` lalu pulihkan status approval
  /// (ledger) dan metrik (uses/successes) dari penyimpanan durabel. Dipakai
  /// setelah install/uninstall Skills Hub agar tanpa restart (B3).
  Future<int> reloadSkills() async {
    final n = await skills.resyncFromDirectory(p.join(workspace, 'skills'));
    skillLedger.applyTo(skills);
    skillMetrics.applyTo(skills);
    return n;
  }

  /// Akar direktori skills/ absolut untuk gerbang promosi skill.
  final String skillsRoot;

  /// Direktori tugas golden (test/golden) absolut untuk evaluasi skill.
  final String goldenDir;
  final JobStore jobs;
  final McpToolLoader mcpLoader;
  final ScriptToolRunner scriptRunner;
  final EvidenceLedger evidence;
  final Map<String, String> mcpEnvironment;

  /// T1 decision model (Jev/Laya). Null when disabled in config.
  final DecisionProvider? decision;
  late final SelfLearningEngine? selfLearningEngine;

  /// Self-evolution loop (B4): trajectory ledger + blended reward + budgeted
  /// LLM judge + UCB1 bandit + quarantine policy. Null when no provider exists.
  late final SelfEvolutionEngine? selfEvolution;

  /// Content-plane guard (prompt injection + secret/PII output redaction).
  final PromptGuard promptGuard;

  /// Sliding-window rate anomaly detector keyed by user.
  final AnomalyDetector anomalyDetector;

  /// Hermes-style plugin registry; hooks dispatch through the permission
  /// gate and chat lifecycle.
  final PluginRegistry plugins;

  /// Layered memory (episodic/semantic/procedural) with decay.
  final LayeredMemory layeredMemory;

  /// Memori terkurasi lintas sesi (MEMORY.md/USER.md) di dataDir/memories.
  final CuratedMemoryStore curatedMemory;

  /// Nudge periodik + penerapan blok memory-ops dari balasan model.
  final MemoryNudgeEngine memoryNudge;

  /// Interrupt-and-redirect: pesan baru saat sesi sibuk memotong turn aktif.
  final TurnRedirectCoordinator turnRedirects;

  /// Hybrid RAG pipeline (dense + BM25 + RRF) shared with the vector index.
  final RagPipeline ragPipeline;

  /// Reflection stage of the self-improving loop; null when disabled.
  final ReflectionEngine? reflectionEngine;

  /// Immutable workspace persona (SOUL.md); null when the file is absent.
  final String? personaPrompt;

  /// Per-session turns accumulated for the reflection stage.
  final Map<String, List<ConversationTurn>> _reflectionTurns = {};

  /// Override provider chat per sesi (`/model <id>`); null = ikut router.
  final Map<String, String> _sessionModel = {};

  /// Model eksplisit per sesi (hasil discovery, Hermes-parity model picker);
  /// hanya berlaku bila [_sessionModel] untuk sesi yang sama terpasang.
  final Map<String, String> _sessionModelChoice = {};

  /// Cache katalog model hasil discovery per provider: (models, fetchedAt).
  final Map<String, (List<String>, DateTime)> _modelCatalog = {};

  /// TTL cache katalog model — parity Hermes (15 menit).
  static const Duration _modelCatalogTtl = Duration(minutes: 15);

  /// Persona bot persisten per chat (`/bot use <id>`); null = tanpa bot.
  final BotStore botStore;

  /// Tim bot persisten + laporan run orkestra (Fase C): `tiko team` /
  /// REST `/v1/teams`; tersimpan di `<dataDir>/teams/`.
  final BotTeamStore botTeamStore;

  /// Indeks + laporan run riset otomatis (Fase D): `tiko research` /
  /// REST `/v1/research/runs`; tersimpan di `<dataDir>/research/`.
  /// Setiap run juga dicerminkan ke papan Kanban `<dataDir>/kanban.json`.
  final ResearchRunStore researchRunStore;

  /// Capability consent plugin (rekomendasi #5): izin per plugin disetujui
  /// eksplisit; default fail-closed.
  final PluginConsentStore pluginConsents;

  /// Plugin yang menunggu consent (`/plugin consent <nama> grant`).
  final Map<String, _PendingPlugin> _pendingPlugins = {};
  late final TirithSecurityLayer tirith;
  late final CredentialManager credentialManager;
  late final FallbackManager fallbackManager;
  Scheduler? _scheduler;
  bool _closed = false;
  bool _mcpStarted = false;
  String resourceProfile = 'standard';

  final TaintTracker _taint = TaintTracker();
  final SessionLock _lock = SessionLock();
  final SecuritySanitizer _sanitizer = SecuritySanitizer();

  /// Run-inspector (GUI-P2-04): live/recent registry of agent turns.
  final TurnInspector turnInspector = TurnInspector();

  /// Cooperative cancellation registry keyed by session id (P1-11). One live
  /// token per running turn; subagent turns chain to their parent's token so
  /// cancelling a parent session also stops its nested subagents.
  final CancellationRegistry cancellations = CancellationRegistry();
  final CapabilityVault capabilities;
  final EventBus events = EventBus();

  /// Hook lifecycle Hermes-parity (P1); null bila tanpa aturan `hooks:`.
  HookExecutor? hookExecutor;
  // Non-final agar tes dapat menyuntik broker dengan TTL pendek.
  late ApprovalBroker approvals;
  late final SkillApprovalLedger skillLedger;
  late final SkillMetricsLedger skillMetrics;
  late final OfflineQueue offlineQueue;

  /// OTLP trace export (P2, opt-in): no-op unless an OTLP/HTTP endpoint is
  /// configured via OTEL_EXPORTER_OTLP_ENDPOINT.
  late final SpanRecorder spans;
  ResourceSnapshot? lastResources;




  /// Relative paths in the config are resolved against [baseDir] (the config
  /// file's directory) so every surface resolves the same locations.
  static Future<TikoRuntime> create({
    String configPath = 'config/agent.yaml',
    bool safe = true,
    bool allowInvalidConfig = false,
    Map<String, String>? env,
    SkillRegistry? skills,
    SelfLearningEngine? selfLearningEngine,
  }) async {
    final (cfg, issues) = TikoConfig.load(configPath);
    final fatalIssues = issues.where((issue) => issue.fatal).toList();
    if (fatalIssues.isNotEmpty && !allowInvalidConfig) {
      throw ConfigValidationException(fatalIssues);
    }
    final baseDir = p.dirname(p.absolute(configPath));
    // Config usually lives in <root>/config/agent.yaml; relative workspace/data
    // paths resolve against <root>. Otherwise against the config's directory.
    final root = p.basename(baseDir) == 'config' ? p.dirname(baseDir) : baseDir;
    String abs(String path) =>
        p.isAbsolute(path) ? path : p.normalize(p.join(root, path));

    final workspace = Directory(abs(cfg.workspace)).absolute.path;
    await Directory(workspace).create(recursive: true);
    final dataDir = abs(cfg.dataDir);
    await Directory(dataDir).create(recursive: true);

    // gateway.env (hasil `tiko setup --interactive`) dimuat otomatis agar
    // SecretRef `env:VAR` resolves tanpa perlu `source` manual. Environment
    // proses (shell/export atau param [env]) tetap menang.
    final fileEnv = OnboardingWizard.loadEnvFileSync(dataDir);
    final baseEnv = env ?? Platform.environment;
    final effectiveEnv = fileEnv.isEmpty
        ? baseEnv
        : <String, String>{...fileEnv, ...baseEnv};

    final factory = ProviderFactory(env: effectiveEnv);
    final providers = factory.buildAll(cfg);
    // FR/T1: decision provider (Jev/Laya systemone) from `decision:` config.
    // Null when disabled → Router falls back to its keyword heuristics.
    final decision = factory.buildDecision(
      cfg,
      providers[cfg.defaultProvider],
    );
    // Memory embedding from `memory.embed`; null keeps the vector path
    // dormant and BM25/FTS authoritative.
    final embedder = factory.buildEmbedder(cfg);

    VectorIndex vectorIndex = BruteForceVectorIndex();
    MemoryStore memory;
    String backend;
    // TIKO_FORCE_JSON_MEMORY=1 skips the sqlite probe entirely — the escape
    // hatch for Termux/eco hosts without libsqlite3 (P2-15).
    final forceJsonMemory =
        effectiveEnv['TIKO_FORCE_JSON_MEMORY'] == '1';
    final sqlite = forceJsonMemory
        ? null
        : await SqliteMemoryStore.tryOpen(
            abs(cfg.dbPath),
            vectorIndex: vectorIndex,
            embedder: embedder,
          );
    if (sqlite != null) {
      // P4: durable vector index over the embeddings table becomes the
      // default when SQLite is available — vectors survive restart without a
      // warm-up rebuild pass (the sqlite-vec extension stays optional and
      // the query path falls back to cosine brute-force over the table).
      final durableIndex = SqliteVecIndex(sqlite.db);
      sqlite.vectorIndex = durableIndex;
      vectorIndex = durableIndex;
      memory = SafeMemoryStore(sqlite);
      backend = 'sqlite-fts5+vec';
    } else {
      memory = SafeMemoryStore(PersistentMemoryStore(dataDir: dataDir, vectorIndex: vectorIndex));
      backend = 'json-fallback (degraded: libsqlite3 tidak tersedia)';
    }

    var sandboxKind = await SandboxRunner.detect();
    var sandbox = SandboxRunner(
      kind: sandboxKind,
      workspacePath: workspace,
      containerPersistent: cfg.sandboxDockerPersistent,
    );
    if (sandboxKind == SandboxKind.none) {
      final cloud = await SandboxRunner.cloudFromEnv(workspacePath: workspace);
      if (cloud != null) {
        sandbox = cloud;
        sandboxKind = cloud.kind;
      }
    }

    final skillRegistry = skills ?? SkillRegistry();
    await skillRegistry.loadFromDirectory(abs('skills'));

    final jobs = JobStore(persistPath: p.join(dataDir, 'jobs.json'));
    await jobs.load();

    final errorMemory = ErrorMemoryStore(
      persistPath: p.join(dataDir, 'errors.json'),
    );

    final leases = LeaseManager();

    final evidence = EvidenceLedger();

    final deferred = DeferredQuestionStore();

    final decisions = DecisionLog();

    final undoLedger = UndoLedger();

    final invariantGuard = InvariantGuard(
      workspaceRoot: workspace,
      sandbox: sandbox,
    );

    final checkpointer = WorkspaceCheckpointer(workspaceRoot: workspace);

    // Advanced memory system: layered memory (episodic/semantic/procedural)
    // plus optional external provider fan-out configured via
    // memory.external_providers.
    final layeredMemory = LayeredMemory();
    await layeredMemory.load(p.join(dataDir, 'layered_memory.json'));

    // Memori asosiatif HDC (D2, eksperimental, in-memory) — pelengkap
    // pencarian asosiatif ringan, bukan pengganti memori semantik.
    final hdcMemory = HdcMemory();

    // Memori terkurasi lintas sesi (MEMORY.md/USER.md) + nudge periodik.
    final curatedMemory = CuratedMemoryStore(
      dataDir: dataDir,
      charBudget: cfg.memoryCuratedCharBudget,
    );
    await curatedMemory.load();
    final memoryNudge = MemoryNudgeEngine(
      store: curatedMemory,
      config: MemoryNudgeConfig(
        enabled: cfg.memoryNudgeIntervalTurns > 0,
        intervalTurns: cfg.memoryNudgeIntervalTurns,
      ),
      guard: const PromptGuard(),
    );

    // Bot Mode: persona persisten per chat (Hermes-parity).
    final botStore = BotStore(dataDir: dataDir);
    await botStore.load();
    final botTeamStore = BotTeamStore(dataDir: dataDir);
    await botTeamStore.load();
    final researchRunStore = ResearchRunStore(dataDir: dataDir);

    // Capability consent plugin (rekomendasi #5): fail-closed — permission
    // yang belum disetujui administrator menahan registrasi plugin.
    final pluginConsents = PluginConsentStore(
      path: p.join(dataDir, 'plugins', 'consents.json'),
    );
    await pluginConsents.load();
    final plugins = PluginRegistry()
      ..consentGuard = (name, requested) =>
          requested.isEmpty || pluginConsents.allGranted(name, requested);

    final externalProviders = [
      for (final c in cfg.memoryProviders)
        switch (c.kind) {
          'mem0' => Mem0MemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: effectiveEnv) ?? '',
              userId: c.name,
              baseUrl: c.baseUrl.isEmpty ? 'https://api.mem0.ai' : c.baseUrl,
            ),
          'honcho' => HonchoMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: effectiveEnv) ?? '',
              sessionId: c.name ?? 'tiko-agent',
              baseUrl: c.baseUrl.isEmpty ? 'https://api.honcho.dev' : c.baseUrl,
            ),
          'supermemory' => SupermemoryMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: effectiveEnv) ?? '',
              userId: c.name,
              baseUrl:
                  c.baseUrl.isEmpty ? 'https://api.supermemory.ai' : c.baseUrl,
            ),
          'hindsight' => HindsightMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: effectiveEnv) ?? '',
              userId: c.name,
              baseUrl: c.baseUrl,
            ),
          _ => HttpMemoryProvider(
              config: HttpMemoryProviderConfig(
                baseUrl: c.baseUrl,
                apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: effectiveEnv),
              ),
              name: c.name,
            ),
        },
    ];
    if (externalProviders.isNotEmpty) {
      memory = _FanoutMemoryStore(memory, externalProviders);
      backend = '$backend + ${externalProviders.length} external provider';
    }

    // Advanced RAG: shares the vector index with the memory store; a null
    // embedder degrades retrieval to lexical-only BM25.
    final ragFts = FtsIndex(p.join(dataDir, 'rag_fts.json'));
    await ragFts.load();
    final rag = RagPipeline(
      dense: vectorIndex,
      lexical: ragFts,
      embedder: embedder,
    );

    // Content-plane guard, rate anomaly detection and the plugin registry.
    final promptGuard = const PromptGuard();
    final anomalyDetector = AnomalyDetector(
      maxEvents: 60,
      window: const Duration(minutes: 1),
    );

    // P1-06: immutable workspace persona (SOUL.md). Read once at startup;
    // the model sees it every turn but cannot rewrite it via tools.
    final soulFile = File(p.join(workspace, 'SOUL.md'));
    final personaPrompt = soulFile.existsSync()
        ? soulFile.readAsStringSync().trim()
        : null;

    // Reflection stage of the self-improving loop (durable lessons).
    final reflection = ReflectionEngine(
      storePath: p.join(dataDir, 'lessons.json'),
    );
    await reflection.load();

    // Image generation breadth: route across FAL.ai and OpenAI Images
    // whenever the matching credentials are configured.
    ImageProvider? imageRouter;
    if (cfg.enableImageGeneration) {
      final imageProviders = <String, ImageProvider>{};
      final falKey = TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: effectiveEnv);
      if (falKey != null && falKey.isNotEmpty) {
        imageProviders['fal'] = FalAiImageProvider(apiKey: falKey);
      }
      final openaiKey = TikoConfig.resolveSecretRef(cfg.openaiApiKeyRef, env: effectiveEnv);
      if (openaiKey != null && openaiKey.isNotEmpty) {
        imageProviders['openai'] = OpenAiImagesProvider(apiKey: openaiKey);
      }
      if (imageProviders.isNotEmpty) {
        imageRouter = ImageModelRouter(providers: imageProviders);
      }
    }

    // Video generation breadth (P2-1): FAL queue API when the FAL key is
    // configured; the tool is registered only when explicitly enabled.
    VideoProvider? videoRouter;
    if (cfg.enableVideoGeneration) {
      final falKey = TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: effectiveEnv);
      if (falKey != null && falKey.isNotEmpty) {
        videoRouter = FalVideoGenerationProvider(apiKey: falKey);
      }
    }

    final sessionStore = FileSessionStore(path: p.join(dataDir, 'sessions.json'));
    final smartHomeTool = SmartHomeTool.fromEnvironment(effectiveEnv);

    final registry = ToolRegistry()
      ..registerAll(createBuiltinTools(
        workspaceRoot: workspace,
        searxngBaseUrl: cfg.searxngBaseUrl,
        tavilyApiKey: TikoConfig.resolveSecretRef(cfg.tavilyApiKeyRef, env: effectiveEnv),
        sandbox: sandbox,
        skillRegistry: skillRegistry,
        falApiKey: TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: effectiveEnv),
        openaiApiKey: TikoConfig.resolveSecretRef(cfg.openaiApiKeyRef, env: effectiveEnv),
        enableImageGeneration: cfg.enableImageGeneration,
        enableVideoGeneration: cfg.enableVideoGeneration,
        videoProvider: videoRouter,
        enableVision: cfg.enableVision,
        imageProvider: imageRouter,
      ))
      ..register(MemorySearchTool(memory))
      ..register(MemoryAddTool(memory))
      ..register(HttpRequestTool(domainAllowlist: cfg.httpDomainAllowlist))
      ..register(PatchFileTool(workspaceRoot: workspace, checkpointer: checkpointer))
      ..register(RollbackTool(checkpointer: checkpointer))
      ..register(ListCheckpointsTool(checkpointer: checkpointer))
      ..register(CdpBrowserTool())
      ..register(ScheduleJobTool(jobs))
      ..register(ListJobsTool(jobs))
      ..register(CancelJobTool(jobs))
      ..register(ErrorLookupTool(store: errorMemory))
      ..register(ErrorRecordTool(store: errorMemory))
      ..register(LeaseTool(manager: leases))
      ..register(InvariantDeclareTool(guard: invariantGuard))
      ..register(InvariantCheckTool(guard: invariantGuard))
      ..register(SecretBrokerTool(sandbox: sandbox))
      ..register(ClaimTool(ledger: evidence))
      ..register(VerifyClaimsTool(ledger: evidence))
      ..register(DeferQuestionTool(store: deferred))
      ..register(const RenderUiTool())
      ..register(AnswerDeferredTool(store: deferred))
      ..register(ListDeferredTool(store: deferred))
      ..register(const EffectPreviewTool())
      ..register(RecordDecisionTool(log: decisions))
      ..register(WhyTool(log: decisions))
      ..register(const ImpactMapTool())
      ..register(RecordUndoableTool(ledger: undoLedger))
      ..register(UndoTool(ledger: undoLedger))
      ..register(ListUndoTool(ledger: undoLedger))
      ..register(RagIngestTool(rag))
      ..register(RagQueryTool(rag))
      ..register(LayeredMemoryTool(layeredMemory))
      ..register(SessionSearchTool(sessionStore))
      ..register(HdcMemoryTool(hdcMemory))
      // D5 federated-lite: export/import skill antar instance (manual,
      // paket JSON tervalidasi, metrik merge LWW; skill impor selalu draft).
      ..register(SkillShareTool(
        registry: skillRegistry,
        skillsRoot: abs('skills'),
      ))
      ..register(KanbanTool(KanbanBoard(p.join(dataDir, 'kanban.json'))))
      ..register(WorktreeTool(WorktreeManager(repoRoot: workspace)));

    // Custom scripts are loaded only when the host has a working OS sandbox.
    // Each tool is namespaced and treated as untrusted output.
    final scriptRunner = ScriptToolRunner(
      toolsDir: abs('tools'),
      sandbox: sandbox,
    );
    final scriptTools = await scriptRunner.loadAll();
    for (final tool in scriptTools) {
      if (registry.get(tool.spec.name) == null) registry.register(tool);
    }

    // MCP child processes start only after agentd acquires its instance lock.
    final mcpLoader = McpToolLoader(
      registry,
      sandbox: sandbox,
      answerServerRequests: cfg.mcpAnswerServerRequests,
    );

    final safety = SafetyState();
    if (safe) safety.enableSafeMode();

    // Initialize Tirith Security Layer (P0 - Critical)
    final tirithConfig = const TirithConfig(
      enabled: true,
      requireApprovalForHighRisk: true,
      requireApprovalForMediumRisk: false,
      autoApproveLowRisk: true,
      approvalTtl: Duration(minutes: 10),
      enableCredentialPools: true,
      enableFallbackProviders: true,
      enableTaintTracking: true,
      sanitizationEnabled: true,
    );
    
    final securityAuditLog = AuditLog(directory: p.join(dataDir, 'logs'));
    
    final permissionGate = MatrixPermissionGate(
      mode: cfg.permissionMode == 'auto' 
          ? PermissionMode.auto 
          : (cfg.permissionMode == 'deny' ? PermissionMode.deny : PermissionMode.ask),
    );
    
    final capabilityGate = CapabilityVault();
    final sanitizer = SecuritySanitizer();
    
    final tirith = TirithSecurityLayer(
      auditLog: securityAuditLog,
      permissionGate: permissionGate,
      capabilityGate: _TirithCapabilityPeek(capabilityGate),
      sanitizer: sanitizer,
      taintTracker: TaintTracker(),
      config: tirithConfig,
    );
    await tirith.initialize();
    
    // Initialize Credential Manager (P0 - Critical)
    final credentialManager = CredentialManager(
      storagePath: p.join(dataDir, 'credentials.json'),
      rotationStrategy: RotationStrategy.leastUsed,
    );
    await credentialManager.initialize();
    
    // Initialize Fallback Manager (P0 - Critical)
    final fallbackConfig = const FallbackConfig(
      fallbacks: [
        // Add default fallback configurations
        FallbackEntry(
          primary: 'openai',
          fallbacks: [
            FallbackProviderConfig(name: 'anthropic'),
            FallbackProviderConfig(name: 'google'),
          ],
        ),
        FallbackEntry(
          primary: 'anthropic',
          fallbacks: [
            FallbackProviderConfig(name: 'openai'),
            FallbackProviderConfig(name: 'mistral'),
          ],
        ),
      ],
      retryAfter: Duration(minutes: 1),
      enableAutomaticFallback: true,
    );
    
    final fallbackManager = FallbackManager(
      config: fallbackConfig,
      maxRetries: 3,
      retryDelay: const Duration(seconds: 1),
      fallbackDelay: const Duration(seconds: 2),
    );
    await fallbackManager.initialize();

    final rt = TikoRuntime._(
      config: cfg,
      issues: issues,
      providers: providers,
      registry: registry,
      sessions: sessionStore,
      memory: memory,
      memoryBackend: backend,
      safety: safety,
      sandboxKind: sandboxKind,
      sandbox: sandbox,
      audit: AuditLog(directory: abs(cfg.logsDir)),
      workspace: workspace,
      dataDir: dataDir,
      skills: skillRegistry,
      skillsRoot: abs('skills'),
      goldenDir: abs('test/golden'),
      jobs: jobs,
      mcpLoader: mcpLoader,
      scriptRunner: scriptRunner,
      evidence: evidence,
      mcpEnvironment: effectiveEnv,
      decision: decision,
      tirith: tirith,
      capabilities: capabilityGate,
      credentialManager: credentialManager,
      fallbackManager: fallbackManager,
      promptGuard: promptGuard,
      anomalyDetector: anomalyDetector,
      plugins: plugins,
      layeredMemory: layeredMemory,
      curatedMemory: curatedMemory,
      memoryNudge: memoryNudge,
      turnRedirects: TurnRedirectCoordinator(),
      botStore: botStore,
      botTeamStore: botTeamStore,
      researchRunStore: researchRunStore,
      pluginConsents: pluginConsents,
      ragPipeline: rag,
      reflectionEngine: reflection,
      personaPrompt: personaPrompt,
      selfLearningEngine: selfLearningEngine,
      smartHomeTool: smartHomeTool.providers.isEmpty ? null : smartHomeTool,
    );
    rt.approvals = ApprovalBroker(p.join(dataDir, 'approvals.json'));
    await rt.approvals.load();
    // Fase D — riset otomatis butuh runtime yang sudah jadi (starter
    // menyusun turn di atas chatWithStatus), jadi didaftarkan di sini.
    rt.registry
      ..register(DeepResearchTool(
        (question) => rt.runResearch(question: question),
      ))
      ..register(ScheduleResearchTool(
        (
          {
            required String question,
            required String cron,
            required String timezone,
            required String channel,
            required String userKey,
          }
        ) =>
            rt.scheduleResearch(
              question: question,
              cron: cron,
              timezone: timezone,
              channel: channel,
              userKey: userKey,
            ),
      ));
    if (rt.smartHomeTool != null && rt.registry.get('smart_home') == null) {
      rt.registry.register(rt.smartHomeTool!);
    }
    // Plugin out-of-process dari config: di-spawn lalu tunduk pada consent
    // (gagal consent → antrean pending, bukan error startup).
    for (final pluginCfg in cfg.processPlugins) {
      final plugin = ProcessPlugin(
        name: pluginCfg.name,
        command: pluginCfg.command,
        args: pluginCfg.args,
      );
      final ok = await rt._registerPluginWithConsent(
        plugin,
        pluginCfg.permissions,
      );
      if (ok) {
        await rt._registerPluginTools(plugin, pluginCfg.permissions);
      }
    }

    // Event hooks (Hermes-parity P1): hanya dipasang bila ada aturan
    // `hooks:` di config; hasil diobservasi lewat event `hook.executed`.
    if (cfg.hooks.isNotEmpty) {
      rt.hookExecutor = HookExecutor(
        events: rt.events,
        rules: cfg.hooks,
        workspace: workspace,
      )..start();
    }
    rt.skillLedger = SkillApprovalLedger(p.join(dataDir, 'skill_approvals.json'));
    await rt.skillLedger.load();
    // Status frontmatter YAML bukan record approval dan memang di-reset oleh
    // loadFromDirectory; hanya ledger durabel yang boleh memulihkan status
    // approved/trial/retired, dan hanya saat fingerprint konten masih cocok.
    rt.skillLedger.applyTo(skillRegistry);
    // Metrik penggunaan skill (uses/successes) juga durabel: ledger
    // memulihkan angka setelah restart dan sink registry mencatat setiap
    // pemakaian/feedback secara fire-and-forget (kegagalan tulis tidak
    // boleh menggagalkan giliran agent).
    rt.skillMetrics = SkillMetricsLedger(p.join(dataDir, 'skill_metrics.json'));
    await rt.skillMetrics.load();
    rt.skillMetrics.applyTo(skillRegistry);
    skillRegistry.onUseRecorded = rt.skillMetrics.recordUse;
    skillRegistry.onFeedbackRecorded = rt.skillMetrics.recordFeedback;
    rt.offlineQueue = OfflineQueue(p.join(dataDir, 'offline'));
    // P2 observability: OTLP/HTTP trace export is opt-in via env and
    // privacy-filtered (see otel.dart allow-list).
    final otelEnv = effectiveEnv;
    final otelEndpoint = otelEnv['OTEL_EXPORTER_OTLP_ENDPOINT']?.trim();
    final otelHeaders = <String, String>{};
    final hdrRaw = otelEnv['OTEL_EXPORTER_OTLP_HEADERS']?.trim() ?? '';
    if (hdrRaw.isNotEmpty) otelHeaders.addAll(_parseOtelHeaders(hdrRaw));
    rt.spans = SpanRecorder(
      exporter: otelEndpoint == null || otelEndpoint.isEmpty
          ? null
          : OtlpHttpTraceExporter(
              endpoint: otelEndpoint.endsWith('/v1/traces')
                  ? otelEndpoint
                  : '${otelEndpoint.replaceAll(RegExp(r'/+$'), '')}/v1/traces',
              headers: otelHeaders,
            ),
    );
    // P2 tool breadth: dynamic tool discovery + controlled multi-step
    // execution. Both see the fully-loaded registry.
    rt.registry.register(ToolSearchTool(() => rt.registry.specs));
    rt.registry.register(ExecuteCodeTool(
      executor: RegistryToolExecutor(rt.registry),
      gate: rt.buildGate(),
    ));
    // ALG-04, P1-09: the subagent tool only works with a runner that executes
    // a nested runtime turn; a bare tool would just emit SUBAGENT_REQUEST.
    // With P1-09 enhancements: budget limits, permission isolation, structured results.
    if (rt.registry.get('spawn_subagent') == null) {
      rt.registry.register(SpawnSubagentTool(
        runner: ({
          required String goal,
          required String context,
          required Session parent,
          required int depth,
          required SubagentBudget budget,
          required Set<String> allowedTools,
        }) => rt._runSubagent(
          goal: goal,
          context: context,
          parent: parent,
          depth: depth,
          budget: budget,
          allowedTools: allowedTools,
        ),
        maxSubagents: 4,
        defaultBudget: const SubagentBudget(),
        defaultAllowedTools: const <String>{},
      ));
    }
    // Hermes-style Skills Hub and cloud browser backends activate only when
    // their credentials are present in the environment.
    final envMap = effectiveEnv;
    final hubUrl = envMap['TIKO_SKILLS_HUB_URL']?.trim() ?? '';
    if (hubUrl.isNotEmpty && rt.registry.get('skills_hub') == null) {
      rt.registry.register(SkillsHubTool(SkillsHubClient(
        config: SkillsHubConfig(
          apiBaseUrl: hubUrl,
          skillsDirectory: p.join(workspace, 'skills'),
          apiKey: envMap['TIKO_SKILLS_HUB_TOKEN']?.trim().isNotEmpty == true
              ? envMap['TIKO_SKILLS_HUB_TOKEN']!.trim()
              : null,
          onChanged: (slug) => rt.reloadSkills(),
        ),
      )));
    }
    final cloudBackends = <CloudBrowserBackend>[];
    final bbKey = envMap['BROWSERBASE_API_KEY']?.trim() ?? '';
    final bbProject = envMap['BROWSERBASE_PROJECT_ID']?.trim() ?? '';
    if (bbKey.isNotEmpty && bbProject.isNotEmpty) {
      cloudBackends.add(BrowserbaseBackend(apiKey: bbKey, projectId: bbProject));
    }
    final buKey = envMap['BROWSER_USE_API_KEY']?.trim() ?? '';
    if (buKey.isNotEmpty) {
      cloudBackends.add(BrowserUseBackend(apiKey: buKey));
    }
    if (cloudBackends.isNotEmpty && rt.registry.get('cloud_browser') == null) {
      rt.registry.register(CloudBrowserTool(CloudBrowserRouter(
        backends: cloudBackends,
      )));
    }
    // NEW-12: forged tools are contract-tested before installation;
    // fail-closed when no OS sandbox can execute the tests.
    if (rt.registry.get('tool_forge') == null) {
      rt.registry.register(ToolForgeTool(
        forge: ToolForge(sandbox: sandbox),
        hasTool: (name) => rt.registry.get(name) != null,
        registerTool: rt.registry.register,
      ));
    }
    // D3: loop koreksi-diri script — opt-in (script.self_repair). Tanpa
    // advisor LLM (provider kosong) tool tidak terdaftar (fail-closed);
    // eksekusi tetap di OS sandbox yang sama dengan script tools.
    if (cfg.scriptSelfRepair && rt.registry.get('script_selfheal') == null) {
      final advisorLlm = rt.auxiliaryLlm();
      if (advisorLlm != null) {
        rt.registry.register(ScriptSelfHealTool(
          runner: SelfCorrectingScriptRunner(
            sandbox: sandbox,
            advisor: LlmScriptRepairAdvisor(advisorLlm),
          ),
          onReport: (report) {
            unawaited(rt.audit.log(
              sessionId: 'selfheal',
              tool: 'script_selfheal',
              args: const {},
              risk: 'high',
              verdict: report.success ? 'allow' : 'deny',
              resultSummary: report.auditSummary(),
            ));
          },
        ));
      }
    }
    // ALG-04: the agent-team tool only works with a runner that executes a
    // nested runtime turn per team member.
    if (rt.registry.get('agent_team') == null) {
      rt.registry.register(AgentTeamTool(
        runner: (systemPrompt, userPrompt, agent) async {
          final eco = rt.resourceProfile == 'eco';
          final outcome = await rt.chatWithStatus(
            userPrompt,
            sessionId:
                'team:${agent.id}:${DateTime.now().microsecondsSinceEpoch}',
            channel: 'team',
            userKey: 'team',
            // Role isolation is enforced for real: an allowlisted member
            // never sees tools outside its list, and each role runs on its
            // own iteration budget (maxTurns) and model tier (modelTier)
            // instead of the host defaults.
            // P2-2: toolAllowlist is now nullable - null means deny all
            toolFilter: agent.toolAllowlist == null
                ? const <String>{}  // Empty set = deny all
                : agent.toolAllowlist!.isEmpty
                    ? null  // Empty list = inherit all (legacy behavior)
                    : Set.of(agent.toolAllowlist!),
            configOverride: AgentConfig(
              maxIterations: agent.maxTurns,
              maxTokensPerTask:
                  eco ? 20000 : cfg.maxTokensPerTask,
              maxWallClockSec: eco ? 120 : cfg.maxWallClockSec,
              maxToolCalls: eco ? 12 : cfg.maxToolCalls,
              preferredTier: modelTierToRouterTier(agent.modelTier),
            ),
            // P1-2: Pass systemPrompt as personaPrompt so it's treated as
            // system message, not user message. This ensures the agent's
            // instructions are not overridden by user task content.
            personaPrompt: systemPrompt.isEmpty ? null : systemPrompt,
          );
          return outcome.text;
        },
      ));
    }
    // Fase C — orkestra bot team satu panggilan: goal → plan → DAG paralel
    // → sintesis → review → gate verifikasi opsional (Fase B).
    if (rt.registry.get('bot_team') == null) {
      rt.registry.register(BotTeamTool(
        starter: ({
          required String goal,
          String? teamId,
          String? verifyCommand,
          int? maxConcurrency,
        }) =>
            rt
                .runBotTeam(
                  goal: goal,
                  teamId: teamId,
                  verifyCommand: verifyCommand,
                  maxConcurrency: maxConcurrency ?? 4,
                )
                .then((r) => r.toJson()),
      ));
    }
    final snap = ResourceMonitor.capture(dataDir: dataDir);
    rt.lastResources = snap;
    rt.resourceProfile = snap.profile;
    
    // Start the self-learning engine for autonomous skill creation and improvement
    await rt.selfLearningEngine?.start();
    rt.selfEvolution?.start();
    
    return rt;
  }

  PermissionMode get _mode => switch (config.permissionMode) {
        'auto' => PermissionMode.auto,
        'deny' => PermissionMode.deny,
        _ => PermissionMode.ask,
      };

  /// Gate that reads risk from `ToolSpec` (fail-closed for unknown tools).
  PermissionGate buildGate({
    Future<bool> Function(ToolCall call, Session session)? confirm,
  }) {
    final matrix = MatrixPermissionGate(
      mode: _mode,
      taint: _taint,
      shellAllowlist: config.shellAllowlist,
      requireConfirm: config.requireConfirm,
      onConfirmRequest: confirm,
      riskResolver: (call) => registry.get(call.name)?.spec.risk,
    );
    final withCap = CapabilityAwareGate(
      inner: matrix,
      validateCapability: (id, call, session) {
        final tok = capabilities.take(id);
        if (tok == null) return 'capability invalid/expired';
        if (tok.sessionId != session.id) return 'capability session mismatch';
        if (tok.tool != call.name) return 'capability tool mismatch';
        // Operasi sempit per tool (PRD §12): 'execute' generik hanya
        // diterima untuk token bergaya lama; token baru menyimpan operasi
        // persis yang disetujui untuk tool itu.
        final operation = CapabilityToken.operationForTool(call.name);
        if (!tok.operations.contains(operation) &&
            !tok.operations.contains('execute')) {
          return 'capability operation mismatch';
        }
        // Binding sumber daya sempit: root token harus memuat file persis
        // yang disentuh call, dan host HTTP harus cocok persis dengan yang
        // disetujui — bukan sekadar "workspace mana pun".
        final roots = CapabilityToken.boundRoots(
          call.name,
          call.args,
          workspaceRoot: workspace,
        );
        final rootOk = roots.every(
          (resource) => tok.roots.any(
            (root) => root == resource || p.isWithin(root, resource),
          ),
        );
        if (!rootOk) return 'capability resource binding mismatch';
        final domains = CapabilityToken.boundDomains(call.name, call.args);
        if (domains.isNotEmpty && !domains.every(tok.domains.contains)) {
          return 'capability domain mismatch';
        }
        try {
          final fingerprint = CapabilityToken.fingerprintArguments(call.args);
          if (fingerprint != tok.argumentsFingerprint) {
            return 'capability arguments changed after approval';
          }
        } catch (_) {
          return 'capability arguments are invalid or oversized';
        }
        if (!_withinApprovedBytes(call, tok.maxBytes)) {
          return 'capability payload exceeds approved byte limit';
        }
        return null;
      },
      // Script and MCP tools are dynamically named. Require the same
      // one-shot permit for every action outside the safe-mode read-only set.
      requiresCapability: (call) {
        final risk = registry.get(call.name)?.spec.risk ?? 'high';
        return (safety.safeMode &&
                !SafetyPermissionGate.safeModeTools.contains(call.name)) ||
            risk == 'high' || risk == 'critical' ||
            call.name.startsWith('mcp_') || call.name.startsWith('script_');
      },
    );
    return _PluginHookGate(SafetyPermissionGate(withCap, safety), plugins);
  }

  /// Unwraps the external-provider bridge so store-specific casts keep
  /// working even when memory search is fanned out.
  MemoryStore get _baseMemory {
    var m = memory;
    if (m is _FanoutMemoryStore) m = m.inner;
    return m;
  }

  /// Deterministic commands (`calc`, `datetime`) - no LLM involved.
  DirectCommandDispatcher directDispatcher({
    Future<bool> Function(ToolCall call, Session session)? confirm,
  }) =>
      DirectCommandDispatcher(
        registry: registry,
        gate: buildGate(confirm: confirm),
        confirm: confirm,
        workspacePath: workspace,
      );

  Router? _routerInstance;
  Router get _router => _routerInstance ??= Router(
        providers: providers,
        defaultProviderId: config.defaultProvider,
        tierProviders: config.tierProviders,
        decision: decision,
        fallbackOrder: [
          config.defaultProvider,
          ...providers.keys.where((k) => k != config.defaultProvider),
        ],
        onFallback: (event) => events.emit('provider.fallback', event),
      );

  Future<Map<String, dynamic>> routeExplain(String text) async {
    final session = Session(id: 'explain', channel: 'cli', userKey: 'local');
    return _router.explain(text, session);
  }

  /// Evaluator golden terisolasi untuk gerbang promosi skill (perbaikan:
  /// "a real isolated golden evaluator"). Setiap tugas golden berjalan di
  /// AgentLoop sendiri dengan: memory in-memory terpisah (evaluasi tidak
  /// pernah menyentuh memory/sesi produksi), registry skill yang hanya
  /// berisi salinan kandidat (metrik skill produksi tidak terpolusi),
  /// [_EvalToolGate] yang menolak semua tool di luar allowlist tugas, dan
  /// sintesis skill dimatikan (threshold 1.0 tak terjangkau) sehingga
  /// evaluasi tidak bisa menulis draft baru ke workspace.
  GoldenTaskEvaluator buildGoldenEvaluator(Skill skill) {
    final candidate = Skill(
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      body: skill.body,
      triggers: skill.triggers,
      tools: skill.tools,
      version: skill.version,
      status: skill.status,
      path: skill.path,
      sha256: skill.sha256,
    );
    return (tasks) async {
      final allowed = <String>{
        for (final task in tasks) ...task.mustCallTools,
        for (final task in tasks) ...task.allowedTools,
        ...skill.tools,
      };
      final harness = GoldenHarness(
        loopFactory: () async {
          final replies = <String>[];
          final evalMemory = SafeMemoryStore(InMemoryStore());
          final evalSkills = SkillRegistry()..register(candidate);
          final loop = AgentLoop(
            router: _router,
            contextBuilder: RuntimeContext(
              registry,
              memory: evalMemory,
              skillRegistry: evalSkills,
              expander: ContextExpander(workspaceRoot: workspace),
            ),
            compactor: Compactor(),
            gate: _EvalToolGate(allowed),
            executor: RegistryToolExecutor(registry),
            memory: evalMemory,
            skillRegistry: evalSkills,
            workspacePath: workspace,
            sanitizer: _sanitizer,
            skillEval: const SkillEvalConfig(threshold: 1.0),
            config: const AgentConfig(
              maxIterations: 6,
              maxTokensPerTask: 20000,
              maxWallClockSec: 60,
              maxToolCalls: 10,
            ),
            reply: (msg, out) async => replies.add(out),
          );
          final session = Session(
            id: 'eval',
            channel: 'eval',
            userKey: 'eval',
          );
          return (
            loop: loop,
            session: session,
            replies: replies,
            tools: const <String>[],
          );
        },
      );
      return harness.run(tasks);
    };
  }

  /// Menjalankan gerbang promosi penuh (scan -> golden) dengan evaluator
  /// terisolasi, lalu mencatat hasilnya di ledger skill.
  Future<SkillGateResult> evaluateSkill(
    String slug, {
    bool promoteOnPass = false,
    String actor = 'cli',
  }) async {
    if (_closed) throw StateError('runtime is closed');
    final skill = skills.get(slug);
    if (skill == null) throw ArgumentError('skill not found: $slug');
    final gate = SkillPromotionGate(
      skillsDir: skillsRoot,
      goldenDir: goldenDir,
      evaluator: buildGoldenEvaluator(skill),
    );
    final result = await gate.evaluateAndMaybePromote(
      skill,
      promoteOnPass: promoteOnPass,
    );
    await skillLedger.append(SkillLedgerRecord(
      slug: slug,
      action: result.ok
          ? (promoteOnPass ? 'trial' : 'evaluated')
          : 'eval_failed',
      actor: actor,
      fingerprint: SkillApprovalLedger.fingerprintOf(skill),
      at: DateTime.now().toUtc(),
      reason: result.message.isEmpty ? null : result.message,
      goldenScore: skill.goldenScore,
      goldenTotal: skill.goldenTotal,
    ));
    events.emit('skill.evaluated', result.toJson()..['actor'] = actor);
    return result;
  }

  /// Menyetujui skill secara durabel: evaluasi golden terisolasi wajib lulus
  /// di proses ini, lalu approval dicatat di ledger supaya bertahan setelah
  /// restart (status frontmatter tidak pernah dipercaya).
  Future<SkillGateResult> approveSkill(
    String slug, {
    String actor = 'cli',
    String? reason,
  }) async {
    if (_closed) throw StateError('runtime is closed');
    if (actor.trim().isEmpty || actor.length > 128) {
      throw ArgumentError.value(actor, 'actor', 'actor wajib diisi (maks 128)');
    }
    final skill = skills.get(slug);
    if (skill == null) throw ArgumentError('skill not found: $slug');
    final gate = SkillPromotionGate(
      skillsDir: skillsRoot,
      goldenDir: goldenDir,
      evaluator: buildGoldenEvaluator(skill),
    );
    final evaluated = await gate.evaluateAndMaybePromote(skill);
    await skillLedger.append(SkillLedgerRecord(
      slug: slug,
      action: evaluated.ok ? 'evaluated' : 'eval_failed',
      actor: actor,
      fingerprint: SkillApprovalLedger.fingerprintOf(skill),
      at: DateTime.now().toUtc(),
      reason: evaluated.message.isEmpty ? null : evaluated.message,
      goldenScore: skill.goldenScore,
      goldenTotal: skill.goldenTotal,
    ));
    events.emit('skill.evaluated', evaluated.toJson()..['actor'] = actor);
    if (!evaluated.ok) {
      return evaluated;
    }
    final result = gate.approve(skill, actor: actor);
    if (result.ok) {
      await skillLedger.append(SkillLedgerRecord(
        slug: slug,
        action: 'approved',
        actor: actor,
        fingerprint: SkillApprovalLedger.fingerprintOf(skill),
        at: DateTime.now().toUtc(),
        reason: reason,
        goldenScore: skill.goldenScore,
        goldenTotal: skill.goldenTotal,
      ));
      events.emit('skill.approved', result.toJson()..['actor'] = actor);
    }
    return result;
  }

  /// Mengembalikan status skill dan mencatat hasilnya di ledger supaya
  /// rollback juga bertahan setelah restart.
  Future<SkillGateResult> rollbackSkill(
    String slug, {
    String to = 'draft',
    String actor = 'cli',
  }) async {
    if (_closed) throw StateError('runtime is closed');
    final skill = skills.get(slug);
    if (skill == null) throw ArgumentError('skill not found: $slug');
    var target = 'draft';
    for (final status in SkillStatus.values) {
      if (status.name == to) target = status.name;
    }
    final gate = SkillPromotionGate(
      skillsDir: skillsRoot,
      goldenDir: goldenDir,
    );
    final result = gate.rollback(skill, to: target);
    await skillLedger.append(SkillLedgerRecord(
      slug: slug,
      action: 'rolled_back',
      actor: actor,
      fingerprint: SkillApprovalLedger.fingerprintOf(skill),
      at: DateTime.now().toUtc(),
      reason: target,
      goldenScore: skill.goldenScore,
      goldenTotal: skill.goldenTotal,
    ));
    events.emit('skill.rolled_back', result.toJson()..['actor'] = actor);
    return result;
  }

  Map<String, dynamic> providerHealth() => _router.healthSnapshot();

  /// Provider & model manager (GUI-P1-05): accessor di atas router yang sama
  /// dengan command `/model`, dipakai REST API + GUI Flutter.
  String? get defaultProviderId => _router.defaultProviderId;

  List<String> providerIds() => _router.providers.keys.toList()..sort();

  Map<String, String> sessionModelOverrides() => Map.unmodifiable(_sessionModel);

  /// Provider efektif untuk satu sesi: override `/model` → default router →
  /// provider id pertama (sorted); null bila tanpa provider.
  String? effectiveSessionProvider(String sessionId) {
    final override = _sessionModel[sessionId];
    if (override != null) return override;
    if (_router.defaultProviderId != null) return _router.defaultProviderId;
    final keys = _router.providers.keys.toList()..sort();
    return keys.isEmpty ? null : keys.first;
  }

  /// Mirror `/model <id>`: pasang override sesi; false bila provider tidak
  /// dikenal.
  bool setSessionProvider(String sessionId, String providerId) {
    if (!_router.providers.containsKey(providerId)) return false;
    _sessionModel[sessionId] = providerId;
    events.emit('model.switched', {
      'session': sessionId,
      'provider': providerId,
    });
    return true;
  }

  /// Mirror `/model default`: lepas override sesi; true bila ada override
  /// yang dilepas.
  bool clearSessionProvider(String sessionId) {
    _sessionModelChoice.remove(sessionId);
    return _sessionModel.remove(sessionId) != null;
  }

  /// Model eksplisit terpasang untuk sesi ini (null bila ikut default).
  String? sessionModelChoice(String sessionId) =>
      _sessionModelChoice[sessionId];

  Map<String, String> sessionModelChoices() =>
      Map.unmodifiable(_sessionModelChoice);

  /// Pasang provider + model eksplisit untuk satu sesi (Hermes-parity
  /// picker: provider dikonfigurasi + model dari discovery). [model] null
  /// berarti pakai model default provider; false bila provider dikenal.
  bool setSessionModel(String sessionId, String providerId, String? model) {
    if (!setSessionProvider(sessionId, providerId)) return false;
    final choice = model?.trim();
    if (choice == null || choice.isEmpty) {
      _sessionModelChoice.remove(sessionId);
    } else {
      _sessionModelChoice[sessionId] = choice;
    }
    return true;
  }

  /// Discovery model live (Hermes-parity): query endpoint daftar model
  /// provider (OpenAI-compat `GET {base}/models`, Ollama `GET {base}/api/tags`)
  /// untuk provider yang TERKONFIGURASI di config/gateway.env — tidak pernah
  /// menebak provider. Cache 15 menit; fail-open (error atau provider tidak
  /// mendukung discovery → daftar kosong).
  Future<Map<String, dynamic>> discoverProviderModels(String providerId) async {
    final id = providerId.trim().toLowerCase();
    if (!_router.providers.containsKey(id)) {
      throw StateError('provider tidak dikenal: $id');
    }
    final raw = _router.providers[id];
    if (raw is! ModelDiscovery) {
      return {
        'provider': id,
        'models': const <String>[],
        'count': 0,
        'discovered': false,
      };
    }
    final ModelDiscovery provider = raw as ModelDiscovery;
    final configuredModel = switch (provider) {
      final OpenAiCompatProvider p => p.model,
      final OllamaNativeProvider p => p.model,
      _ => null,
    };
    final cached = _modelCatalog[id];
    final now = DateTime.now();
    if (cached == null || now.difference(cached.$2) >= _modelCatalogTtl) {
      final models = await provider.discoverModels();
      _modelCatalog[id] = (models, now);
    }
    final fresh = _modelCatalog[id]!.$1;
    return {
      'provider': id,
      'models': fresh,
      'count': fresh.length,
      'discovered': true,
      if (configuredModel != null) 'configured_model': configuredModel,
    };
  }

  /// Unified provider health (P1): [CircuitBreaker] adapter over the SAME
  /// [ProviderHealth] state the Router uses for selection/fallback. Any
  /// surface that calls a provider directly (scheduler delivery, gateway
  /// tools, scripts) should acquire/record through this breaker so its
  /// failures and probes are instantly visible to the Router — one state
  /// machine per provider, no divergent health counters.
  ///
  /// The chat path records exactly once via AgentLoop; do not ALSO wrap
  /// those providers in [BreakerLlmProvider] with this health or failures
  /// would be double-counted.
  CircuitBreaker breakerFor(String providerId) {
    final h = _router.health.putIfAbsent(
      providerId,
      () => ProviderHealth(clock: _router.clock),
    );
    return CircuitBreaker(health: h);
  }

  /// Provider pertama untuk jalur auxiliar (skill synthesis, self-learning)
  /// yang memanggil LLM di luar AgentLoop: dibungkus [BreakerLlmProvider]
  /// dengan [ProviderHealth] yang SAMA dengan Router, sehingga kegagalan
  /// jalur ini terlihat Router dan provider mati di-gate breaker, bukan
  /// dicoba terus. Chat utama tetap dicatat sekali via AgentLoop.
  LlmProvider? auxiliaryLlm() {
    if (_router.providers.isEmpty) return null;
    final inner = _router.providers.values.first;
    final health = _router.health.putIfAbsent(
      inner.id,
      () => ProviderHealth(clock: _router.clock),
    );
    return BreakerLlmProvider(inner, health: health);
  }

  /// Record a provider failure from any direct-use surface; lands in the
  /// same [ProviderHealth] the Router and [breakerFor] share.
  void recordProviderFailure(String providerId, String error) =>
      _router.recordFailure(providerId, error);

  /// Record a provider success (with latency) from any direct-use surface.
  void recordProviderSuccess(String providerId, double latencyMs) =>
      _router.recordSuccess(providerId, latencyMs);

  /// Cooperatively cancels the turn running in [sessionId] (and, by chaining,
  /// its nested subagents). Returns true when a live turn was cancelled.
  bool cancelTurn(String sessionId) => cancellations.cancel(sessionId);

  /// Cancels every live turn (runtime shutdown / kill switch support).
  void cancelAllTurns() => cancellations.cancelAll();

  /// Provider instance by config id (for `tiko models` discovery).
  LlmProvider? providerById(String id) => _router.providers[id];

  /// Admin view of memory facts. Unwraps the safety decorator so both
  /// SQLite and JSON fallback backends expose the same interface.
  Future<List<Map<String, dynamic>>> listMemories({int limit = 200}) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..1000');
    }
    final store = _baseMemory is SafeMemoryStore
        ? (_baseMemory as SafeMemoryStore).inner
        : _baseMemory;
    final facts = <Fact>[];
    if (store is SqliteMemoryStore) {
      final rows = await store.listFacts(limit: limit);
      return rows;
    }
    if (store is PersistentMemoryStore) {
      facts.addAll(store.facts.values);
    } else if (store is InMemoryStore) {
      facts.addAll((await store.listFacts()));
    }
    facts.sort((a, b) => b.importance.compareTo(a.importance));
    return facts.take(limit).map((fact) => {
      'id': fact.id,
      'text': fact.text,
      'kind': fact.kind,
      'importance': fact.importance,
      'provenance': fact.provenance.name,
      'confidence': fact.confidence,
      'ttl_days': fact.ttlDays,
      'state': fact.state,
    }).toList(growable: false);
  }

  /// Delete by stable fact ID through the same decorated runtime store.
  /// P4 parity: imports conversation history from other agents (Claude Code
  /// session JSONL, ChatGPT export, generic JSON) into memory as searchable
  /// facts.
  Future<MigrationReport> migrateHistory(
    String path, {
    String? format,
    String? ownerKey,
  }) =>
      AgentMigration(store: _baseMemory).importFile(
        path,
        format: format,
        ownerKey: ownerKey,
      );

  Future<bool> deleteMemory(String id) async {
    if (id.isEmpty || id.length > 128 || id.contains('\u0000')) return false;
    final store = _baseMemory is SafeMemoryStore
        ? (_baseMemory as SafeMemoryStore).inner
        : _baseMemory;
    if (store is SqliteMemoryStore) return store.deleteFact(id);
    if (store is PersistentMemoryStore) return store.deleteFact(id);
    if (store is InMemoryStore) {
      final existed = store.facts.containsKey(id);
      if (!existed) return false;
      await store.deleteFact(id);
      return true;
    }
    return false;
  }

  Future<DirectResult> direct(
    String command,
    List<String> args, {
    Future<bool> Function(ToolCall call, Session session)? confirm,
  }) {
    return directDispatcher(confirm: confirm).run(command, args);
  }

  /// Backwards-compatible text-only chat API.
  Future<String> chat(
    String text, {
    String sessionId = 'cli:default',
    String channel = 'cli',
    String userKey = 'local',
    Future<bool> Function(ToolCall call, Session session, String approvalId)?
        confirm,
    void Function(String delta)? onTextDelta,
    void Function(ToolCallTrace trace)? onToolTrace,
    void Function(String toolName)? onToolStart,
    List<Attachment> attachments = const [],
  }) async => (await chatWithStatus(
        text,
        sessionId: sessionId,
        channel: channel,
        userKey: userKey,
        confirm: confirm,
        onTextDelta: onTextDelta,
        onToolTrace: onToolTrace,
        onToolStart: onToolStart,
        attachments: attachments,
      )).text;

  /// One agent turn with explicit completion status for durable queues/jobs.
  /// Instrumented for the Run-inspector: every call registers a bounded-run
  /// entry (input preview, tool steps, outcome) observable via
  /// [turnInspectorSnapshot].
  Future<ChatRunResult> chatWithStatus(
    String text, {
    String sessionId = 'cli:default',
    String channel = 'cli',
    String userKey = 'local',
    Future<bool> Function(ToolCall call, Session session, String approvalId)?
        confirm,
    PermissionGate? gateOverride,
    AgentConfig? configOverride,
    Set<String>? toolFilter,
    void Function(String delta)? onTextDelta,

  /// C4 Chat-UX: hook live per tool turn (trace tersanitasi; durasi nyata).
  /// Kegagalan callback pemanggil tidak diteruskan runtime.
    void Function(ToolCallTrace trace)? onToolTrace,

  /// C4 Chat-UX: nama tool tepat sebelum dieksekusi (start). Eksekusi
  /// paralel berarti beberapa start bisa aktif bersamaan.
    void Function(String toolName)? onToolStart,
    bool internalCommand = false,
    String? interruptNote,
    String? personaPrompt,
    List<Attachment> attachments = const [],
  }) async {
    final inputPreview = _sanitizer.output(
      text.length > 240 ? '${text.substring(0, 240)}…' : text,
    );
    final entry = turnInspector.begin(
      session: sessionId,
      channel: channel,
      input: inputPreview,
    );
    try {
      // @ context references (Hermes-parity P3): diekspansi fail-closed
      // sebelum turn dijalankan; perintah internal (`/…`) tidak disentuh.
      var prompt = text;
      if (!internalCommand &&
          !text.trim().startsWith('/') &&
          text.contains('@')) {
        try {
          final expansion = await expandContextRefs(prompt,
              workspace: workspace);
          if (expansion.refs.isNotEmpty) {
            prompt = expansion.text;
            events.emit('context.expanded', {
              'session_id': sessionId,
              'ok': expansion.refs.where((r) => r['status'] == 'ok').length,
              'failed':
                  expansion.refs.where((r) => r['status'] == 'error').length,
              'refs': expansion.refs,
            });
          }
        } catch (_) {
          // Kegagalan ekspansi tidak boleh menggagalkan pengiriman pesan;
          // penanda error inline tetap memberi konteks yang jujur.
        }
      }
      // C2 Chat-UX: attachment pengguna diekspansi fail-closed jadi konteks
      // teks (file teks dibaca bounded; gambar/biner  hanya metadata). Pesan
      // internal (perintah actions) tidak menyertakan attachment, jadi tanpa
      // guard internal pun blok tetap tidak terbentuk.
      if (attachments.isNotEmpty) {
        // A.2/A.3: ingest penuh — teks inline, zip diekstrak ke folder,
        // dokumen diekstrak teksnya, file biner disimpan ke uploads (path
        // dirujuk; gambar dibawa ke provider vision via RuntimeContext).
        final expansion = ingestAttachments(
          attachments,
          uploadsDirPath: p.join(
            dataDir,
            'uploads',
            sanitizeSessionDirName(sessionId),
          ),
        );
        if (expansion.text.isNotEmpty) {
          prompt = prompt.isEmpty
              ? expansion.text
              : '$prompt\n\n${expansion.text}';
          events.emit('attachments.expanded', {
            'session_id': sessionId,
            'stats': expansion.stats,
          });
        }
      }
      final result = await _chatWithStatusCore(
        prompt,
        sessionId: sessionId,
        channel: channel,
        userKey: userKey,
        confirm: confirm,
        gateOverride: gateOverride,
        configOverride: configOverride,
        toolFilter: toolFilter,
        onTextDelta: onTextDelta,
        onToolTrace: onToolTrace,
        onToolStart: onToolStart,
        internalCommand: internalCommand,
        interruptNote: interruptNote,
        personaPrompt: personaPrompt,
        attachments: attachments,
        turnEntry: entry,
      );
      turnInspector.finish(
        entry.id,
        success: result.success,
        tokensUsed: result.tokensUsed,
        toolCalls: result.toolCallCount,
        answer: _sanitizer.output(
          result.text.length > 240 ? '${result.text.substring(0, 240)}…' : result.text,
        ),
      );
      return result;
    } catch (error) {
      turnInspector.fail(entry.id, error: _sanitizer.output('$error'));
      rethrow;
    }
  }

  Future<ChatRunResult> _chatWithStatusCore(
    String text, {
    String sessionId = 'cli:default',
    String channel = 'cli',
    String userKey = 'local',
    Future<bool> Function(ToolCall call, Session session, String approvalId)?
        confirm,
    PermissionGate? gateOverride,
    AgentConfig? configOverride,
    Set<String>? toolFilter,
    void Function(String delta)? onTextDelta,
    bool internalCommand = false,
    String? interruptNote,
    String? personaPrompt,
    List<Attachment> attachments = const [],
    InspectedRun? turnEntry,
    void Function(ToolCallTrace trace)? onToolTrace,
    void Function(String toolName)? onToolStart,
  }) async {
    // Turn internal (/learn authoring) berjalan di bawah lock panggilan
    // luarnya — SessionLock tidak re-entrant.
    final locked = !internalCommand;
    if (locked && !_lock.tryAcquire(sessionId)) {
      // Interrupt-and-redirect: alih-alih menolak, batalkan turn aktif
      // secara kooperatif dan tunggu lock lepas (bounded).
      if (!internalCommand && config.interruptRedirect) {
        final hadLiveTurn = cancellations.tokenOf(sessionId) != null;
        final ready = await turnRedirects.interruptAndWait(
          cancelActive: () => cancellations.cancel(sessionId),
          isBusy: () => _lock.isBusy(sessionId),
        );
        if (ready) {
          if (hadLiveTurn) {
            events.emit('turn.interrupted', {
              'session': sessionId,
              'channel': channel,
            });
          }
          return chatWithStatus(
            text,
            sessionId: sessionId,
            channel: channel,
            userKey: userKey,
            confirm: confirm,
            gateOverride: gateOverride,
            configOverride: configOverride,
            toolFilter: toolFilter,
            onTextDelta: onTextDelta,
            internalCommand: internalCommand,
            interruptNote: hadLiveTurn
                ? 'Turn sebelumnya diinterupsi oleh pesan baru dari '
                    'pengguna. Abaikan arah turn lama dan kerjakan '
                    'permintaan terbaru ini.'
                : null,
          );
        }
      }
      return const ChatRunResult(
        text: 'Sesi masih memproses pesan sebelumnya.',
        success: false,
        retryable: true,
      );
    }
    try {
      if (!internalCommand) {
        final learnRequest = LearnCommand.parse(text);
        if (learnRequest != null) {
          return await _runLearnTurn(
            learnRequest,
            sessionId: sessionId,
            channel: channel,
            userKey: userKey,
            confirm: confirm,
          );
        }
        if (text.trim() == '/memory') {
          return _curatedMemoryStatus();
        }
        final modelCmd = _parseModelCommand(text);
        if (modelCmd != null) {
          return _modelCommand(modelCmd, sessionId: sessionId);
        }
        if (text.trim() == '/tools') {
          return _toolsCommand();
        }
        final botCmd = _parseBotCommand(text);
        if (botCmd != null) {
          return await _botCommand(botCmd, sessionId: sessionId);
        }
        final pluginCmd = _parsePluginCommand(text);
        if (pluginCmd != null) {
          return await _pluginCommand(pluginCmd);
        }
      }
      final session = await sessions.getOrCreate(
        sessionId,
        channel: channel,
        userKey: userKey,
      );
      final boundBot = botStore.botFor(sessionId);
      if (!internalCommand && boundBot != null) {
        final bot = boundBot;
        if (bot.toolAllowlist.isEmpty) {
          return ChatRunResult(
            text: 'Bot "${bot.id}" belum memiliki tool allowlist — '
                'turn ditolak fail-closed. Atur: /bot allow ${bot.id} '
                '<tool1,tool2> atau nonaktifkan: /bot off.',
            success: false,
          );
        }
        final botFilter = Set.of(bot.toolAllowlist);
        toolFilter = toolFilter == null
            ? botFilter
            : toolFilter.intersection(botFilter);
      }
      // Content-plane guard: block injection attempts and sanitize the rest.
      final now = DateTime.now().toUtc();
      final guardVerdict = promptGuard.inspectInput(
        text,
        provenance: Provenance.user,
      );
      if (guardVerdict.blocked) {
        _guardBlockedTurns += 1;
        events.emit('guard.blocked', {
          'session': sessionId,
          'findings':
              guardVerdict.findings.map((f) => f.toJson()).toList(),
        });
        return ChatRunResult(
          text: 'Permintaan diblokir PromptGuard: '
              '${guardVerdict.findings.map((f) => f.ruleId).join(', ')}',
          success: false,
        );
      }
      if (guardVerdict.sanitizedText != null) _guardSanitizedTurns += 1;
      final effectiveText = guardVerdict.sanitizedText ?? text;
      anomalyDetector.record(userKey, now);
      if (anomalyDetector.isAnomalous(userKey, now)) {
        return const ChatRunResult(
          text: 'Laju permintaan tidak wajar; coba lagi nanti.',
          success: false,
          retryable: true,
        );
      }
      await plugins.dispatchMessage(session.id, effectiveText, fromUser: true);
      final replies = <String>[];
      final defaultConfig = AgentConfig(
          maxIterations: resourceProfile == 'eco' ? 6 : config.maxIterations,
          maxTokensPerTask: resourceProfile == 'eco' ? 20000 : config.maxTokensPerTask,
          maxWallClockSec: resourceProfile == 'eco' ? 120 : config.maxWallClockSec,
          maxToolCalls: resourceProfile == 'eco' ? 12 : config.maxToolCalls,
        );
      final projCtx = resolveProjectContextFile(workspaceRoot: workspace);
      final loop = AgentLoop(
        router: _router,
        contextBuilder: RuntimeContext(
          registry,
          memory: memory,
          sessions: sessions,
          skillRegistry: skills,
          expander: ContextExpander(workspaceRoot: workspace),
          toolFilter: toolFilter,
          // P1-2: Use the explicit personaPrompt parameter if provided,
          // otherwise fall back to the bot's persona.
          personaPrompt: personaPrompt ?? botStore.botFor(sessionId)?.persona,
          reflectionEngine: reflectionEngine,
          ragPipeline: ragPipeline,
          layeredMemory: layeredMemory,
          curatedMemoryBlock: curatedMemory.snapshotPromptBlock(),
          nudgeDirective: memoryNudge.shouldNudge(sessionId)
              ? MemoryNudgeEngine.directive
              : null,
          interruptNote: interruptNote,
          botPersona: botStore.botFor(sessionId)?.persona,
          // A.1 — project context file TIKO.md/AGENTS.md/... dari root
          // workspace, dibaca per-turn (murah, selalu fresh), fail-closed.
          projectContextName: projCtx?.fileName,
          projectContextBlock: projCtx?.content,
          toolSubsetThreshold: config.toolSubsetThreshold,
          toolSubsetK: config.toolSubsetK,
        ),
        compactor: Compactor(),
        // P0-3: the gate never prompts directly. It returns needsConfirm and
        // the loop's broker-backed confirm below becomes the single path, so
        // every surface settles the same durable apr_* request ID.
        gate: _TirithPreGate(
          gateOverride ?? _botGate(boundBot),
          tirith,
          channel,
        ),
        executor: RegistryToolExecutor(registry),
        memory: memory,
        skillRegistry: skills,
        skillsDir: p.join(workspace, 'skills'),
        workspacePath: workspace,
        isToolParallelSafe: (call) =>
            registry.get(call.name)?.spec.parallelSafe ?? false,
        sanitizer: _sanitizer,
        sessionStore: sessions,
        taintMark: _taint.mark,
        // FR-01: reuse the first configured provider for skill-synthesis
        // reflection; AgentLoop falls back to the naive draft when absent.
        synthLlm: auxiliaryLlm(),
        shouldStop: () => safety.stopRequested,
        config: configOverride ?? defaultConfig,
        // P1-4: sanitize each delta before it reaches a live chat message;
        // the final reply is additionally guarded below as usual.
        onTextDelta:
            onTextDelta == null ? null : (d) => onTextDelta(_sanitizer.output(d)),
        onToolCallStart:
            onToolStart == null ? null : (call) => onToolStart(call.name),
        onToolTrace: onToolTrace,
        audit: (call, verdict, result) {
          final entry = turnEntry;
          if (entry != null) {
            turnInspector.recordTool(
              entry.id,
              tool: call.name,
              verdict: verdict.verdict.name,
              isError: result.isError,
              durationMs: result.durationMs ?? 0,
            );
          }
          evidence.recordCall(result.callId, call.name, result.content);
          unawaited(plugins.dispatchAfterToolCall(
            ToolHookInput(
              toolName: call.name,
              args: call.args,
              sessionId: session.id,
            ),
            result.content,
            result.isError,
          ));
          unawaited(
            audit.log(
              sessionId: session.id,
              tool: call.name,
              args: call.args,
              // Risk comes from the declared spec (not a hard-coded name list).
              risk: registry.get(call.name)?.spec.risk ?? 'high',
              verdict: verdict.verdict.name,
              resultSummary: _sanitizer.output(
                result.content.length > 500
                    ? result.content.substring(0, 500)
                    : result.content,
              ),
              durationMs: result.durationMs,
              error: result.isError ? _sanitizer.output(result.content) : null,
            ),
          );
        },
        reply: (msg, out) async => replies.add(out),
        confirm: (call, sess) async {
          final risk = registry.get(call.name)?.spec.risk ?? 'high';
          final req = await approvals.create(session: sess, call: call, risk: risk);
          events.emit('approval.pending', req.toJson());

          if (confirm != null) {
            // The channel callback is a notifier/prompt, not a second source
            // of truth. Run it concurrently with the broker wait so Flutter,
            // REST, Telegram and CLI decisions all settle this same request.
            // The approval ID is handed to the prompt so the user can resolve
            // it from any other surface (web, Flutter, tiko approve).
            unawaited(() async {
              try {
                final userDecision = await confirm(call, sess, req.id);
                await decideApproval(
                  req.id,
                  approve: userDecision,
                  actor: 'confirm_fn',
                  reason: userDecision ? null : 'channel user rejected',
                );
              } catch (error) {
                try {
                  await decideApproval(
                    req.id,
                    approve: false,
                    actor: 'confirm_error',
                    reason: 'confirmation channel failed: $error',
                  );
                } catch (_) {
                  // The broker remains fail-closed if persistence itself fails.
                }
                events.emit('approval.channel_error', {
                  'id': req.id,
                  'tool': call.name,
                  'error': _sanitizer.output('$error'),
                });
              }
            }());
          } else {
            // Headless HTTP/Flutter: the approval request is visible in the
            // shared REST/WebSocket feed and resolved by the same broker.
            stdoutWrite(
              'Approval ${req.id} tool=${call.name} — approve via API/Flutter '
              'or run tiko approve ${req.id}',
            );
          }
          final ok = await approvals.wait(req.id);
          if (!ok) {
            events.emit('approval.denied', {'id': req.id, 'tool': call.name});
            return false;
          }
          final tok = capabilities.issue(CapabilityToken.mint(
            sessionId: sess.id,
            tool: call.name,
            // Operasi + sumber daya sempit: token hanya berlaku untuk file
            // (atau host) yang persis disetujui user pada panggilan ini.
            operations: [CapabilityToken.operationForTool(call.name)],
            roots: CapabilityToken.boundRoots(
              call.name,
              call.args,
              workspaceRoot: workspace,
            ),
            domains: CapabilityToken.boundDomains(call.name, call.args),
            arguments: call.args,
          ));
          call.args['_capability_id'] = tok.id;
          events.emit('tool.approved', {
            'tool': call.name,
            'capability_id': tok.id,
            'approval_id': req.id,
            'session': sess.id,
          });
          return true;
        },
      );
      final turnStart = DateTime.now();
      final cancelToken = cancellations.begin(sessionId);
      // Subagent turns chain to the parent's token: cancelling the parent
      // session also stops this nested turn at its next boundary.
      final subMarker = '/sub/';
      final subIdx = sessionId.indexOf(subMarker);
      if (subIdx > 0) {
        final parentToken = cancellations.tokenOf(sessionId.substring(0, subIdx));
        if (parentToken != null) {
          unawaited(parentToken.whenCancelled.then((_) => cancelToken.cancel()));
        }
      }
      final overrideProvider = _sessionModel[sessionId];
      final choice = _sessionModelChoice[sessionId];
      LlmProvider? preferredLlm;
      if (overrideProvider != null && choice != null) {
        final pinned = _router.providers[overrideProvider];
        if (pinned is OpenAiCompatProvider) {
          preferredLlm = pinned.withModel(choice);
        } else if (pinned is OllamaNativeProvider) {
          preferredLlm = pinned.withModel(choice);
        }
      }
      await loop.handle(
        InboundMessage(
          channel: channel,
          userKey: userKey,
          sessionKey: sessionId,
          text: effectiveText,
          // Gambar mentah diteruskan untuk vision (RuntimeContext membaca
          // attachment type image di sini); teks sudah diekspansi di prompt.
          attachments: attachments,
        ),
        session,
        cancelToken: cancelToken,
        preferredProviderId:
            overrideProvider ?? botStore.botFor(sessionId)?.model,
        preferredLlm: preferredLlm,
      );
      var answer = replies.join('\n');
      final curatedReport = await memoryNudge.processReply(answer);
      if (curatedReport.cleanedReply != null) {
        answer = curatedReport.cleanedReply!;
      }
      if (curatedReport.applied.isNotEmpty ||
          curatedReport.rejected.isNotEmpty) {
        events.emit('memory.curated', {
          'session': sessionId,
          'applied': curatedReport.applied,
          'rejected': curatedReport.rejected,
        });
      }
      final outbound = promptGuard.inspectOutput(answer);
      await _learnOnTurn(
        session: session,
        userText: effectiveText,
        assistantText: answer,
        success: loop.lastTurnSucceeded,
        traces: loop.lastToolCalls,
        tokensUsed: loop.lastTokensUsed,
      );
      unawaited(_reflectOnTurn(
        sessionId: session.id,
        userText: effectiveText,
        assistantText: answer,
        success: loop.lastTurnSucceeded,
      ));
      final result = ChatRunResult(
        text: outbound.sanitizedText ?? answer,
        success: loop.lastTurnSucceeded,
        retryable: !loop.lastTurnSucceeded,
        tokensUsed: loop.lastTokensUsed,
        toolCallCount: loop.lastToolCalls.length,
        toolCallTraces: loop.lastToolCalls,
        skillsUsed: loop.lastSkillsUsed,
      );
      _rememberSessionSkills(session.id, result.skillsUsed);
      unawaited(_checkTokenAnomaly(session, result));
      unawaited(_runIdleConsolidation(session.id));
      unawaited(spans.recordTurn(
        traceId: session.id,
        attributes: {
          'tiko.session_id': session.id,
          'tiko.channel': channel,
          'tiko.tokens_used': result.tokensUsed,
          'tiko.tool_call_count': result.toolCallCount,
          'tiko.success': result.success,
          'tiko.duration_ms':
              DateTime.now().difference(turnStart).inMilliseconds,
        },
        startEpochMs: turnStart.millisecondsSinceEpoch,
        endEpochMs: DateTime.now().millisecondsSinceEpoch,
        success: result.success,
      ));
      return result;
    } finally {
      if (locked) _lock.release(sessionId);
    }
  }

  /// Tool yang boleh dipakai saat turn authoring /learn — hanya baca/ambil
  /// materi; penulisan skill dilakukan runtime setelah validasi.
  static const Set<String> _learnToolAllowlist = {
    'read_file',
    'list_dir',
    'grep',
    'web_fetch',
    'http_request',
    'session_search',
  };

  /// `/learn <sumber>` — jalankan turn authoring dengan toolset terbatas,
  /// lalu validasi + simpan hasilnya sebagai draft skill.
  Future<ChatRunResult> _runLearnTurn(
    LearnRequest request, {
    required String sessionId,
    required String channel,
    required String userKey,
    Future<bool> Function(ToolCall call, Session session, String approvalId)?
        confirm,
  }) async {
    final known = registry.specs.map((s) => s.name).toSet();
    final toolFilter = _learnToolAllowlist.intersection(known);
    final authored = await chatWithStatus(
      LearnPrompt.userPrompt(request),
      sessionId: sessionId,
      channel: channel,
      userKey: userKey,
      confirm: confirm,
      toolFilter: toolFilter,
      internalCommand: true,
    );
    if (!authored.success) return authored;

    final markdown = LearnOutput.extractSkillMarkdown(authored.text);
    if (markdown == null) {
      return ChatRunResult(
        text: 'Tidak menemukan blok ```skill-markdown pada balasan model. '
            'Coba ulang /learn dengan sumber lebih spesifik.\n\n${authored.text}',
        success: false,
        retryable: true,
        tokensUsed: authored.tokensUsed,
        toolCallCount: authored.toolCallCount,
      );
    }

    final skill = SkillParser.parse(markdown);
    if (skill == null) {
      return const ChatRunResult(
        text: 'SKILL.md hasil /learn tidak bisa diparse (frontmatter tidak '
            'valid). Perbaiki format lalu ulangi.',
        success: false,
        retryable: true,
      );
    }
    if (Directory(p.join(skillsRoot, skill.slug)).existsSync()) {
      return ChatRunResult(
        text: 'Skill `${skill.slug}` sudah ada di skills/. Hapus atau pilih '
            'nama lain sebelum mengulang /learn.',
        success: false,
        retryable: true,
      );
    }
    final validationError =
        SkillValidator.validate(skill, knownTools: known);
    if (validationError != null) {
      return ChatRunResult(
        text: 'Skill `${skill.slug}` ditolak validator: $validationError',
        success: false,
        retryable: true,
      );
    }
    final scan = SkillScanner.scanContent(markdown);
    if (!scan.ok) {
      return ChatRunResult(
        text: 'Skill `${skill.slug}` gagal static scan: '
            '${scan.findings.join('; ')}',
        success: false,
        retryable: true,
      );
    }
    final saved = await SkillDraftBuilder.saveDraft(
      markdown,
      skillsDir: skillsRoot,
      knownTools: known,
    );
    if (saved == null) {
      return ChatRunResult(
        text: 'Skill `${skill.slug}` gagal disimpan (validasi akhir gagal).',
        success: false,
        retryable: true,
      );
    }
    skills.register(saved);
    events.emit('skill.learned', {
      'session': sessionId,
      'slug': saved.slug,
      'sources': request.sources.map((s) => '${s.type}:${s.value}').toList(),
      'focus': request.focus,
    });
    final descWarning = saved.description.length > 60
        ? '\nCatatan: deskripsi ${saved.description.length} char — standar '
            'house maksimal 60; pertimbangkan dipangkas saat approval.'
        : '';
    return ChatRunResult(
      text: 'Skill draft tersimpan: ${saved.slug}\n'
          'Nama: ${saved.name}\n'
          'Deskripsi: ${saved.description}\n'
          'Lokasi: ${p.join(skillsRoot, saved.slug, 'SKILL.md')}'
          '$descWarning\n\n'
          'Lanjutan: `tiko skills evaluate ${saved.slug} --promote` untuk '
          'menguji, lalu `tiko skills approve ${saved.slug}`.',
      success: true,
      tokensUsed: authored.tokensUsed,
      toolCallCount: authored.toolCallCount,
      toolCallTraces: authored.toolCallTraces,
    );
  }

  /// Parse perintah `/model [id|default|list]`; null bila bukan /model.
  _ModelCommand? _parseModelCommand(String text) {
    final trimmed = text.trim();
    if (!RegExp(r'^/model(?:\s|$)', caseSensitive: false).hasMatch(trimmed)) {
      return null;
    }
    final arg = trimmed.substring('/model'.length).trim();
    return _ModelCommand(arg: arg.isEmpty ? 'list' : arg);
  }

  /// `/model` — parity Hermes: lihat/switch provider chat runtime.
  ChatRunResult _modelCommand(_ModelCommand cmd, {required String sessionId}) {
    final ids = _router.providers.keys.toList()..sort();
    final arg = cmd.arg.toLowerCase();
    if (arg == 'list') {
      final current = _sessionModel[sessionId] ??
          _router.defaultProviderId ??
          ids.first;
      final buf = StringBuffer('Provider tersedia (sesi ini: $current):\n');
      for (final id in ids) {
        final health = _router.health[id];
        final state = health?.state ?? 'unknown';
        buf.writeln('- $id (health=$state)');
      }
      buf.write('\nGanti: /model <id> · kembali default: /model default');
      return ChatRunResult(text: buf.toString(), success: true);
    }
    if (arg == 'default') {
      _sessionModel.remove(sessionId);
      return const ChatRunResult(
        text: 'Sesi ini kembali memakai provider default dari router.',
        success: true,
      );
    }
    if (!_router.providers.containsKey(arg)) {
      return ChatRunResult(
        text: 'Provider "$arg" tidak dikenal. Provider tersedia: '
            '${ids.join(", ")}.',
        success: false,
        retryable: true,
      );
    }
    _sessionModel[sessionId] = arg;
    events.emit('model.switched', {
      'session': sessionId,
      'provider': arg,
    });
    return ChatRunResult(text: 'Sesi ini memakai provider: $arg', success: true);
  }

  /// Snapshot event hooks (Hermes-parity P1): aturan terpasang + statistik
  /// fire; kosong bila fitur tidak dikonfigurasi.
  Map<String, dynamic> hookSnapshot() {
    final executor = hookExecutor;
    if (executor == null) {
      return {
        'rules': <Map<String, dynamic>>[],
        'stats': <String, Map<String, dynamic>>{},
      };
    }
    return executor.snapshot();
  }

  /// Snapshot plugin + consent untuk REST/GUI (GUI-P1-06, paritas
  /// `/plugin list|info`): plugin terdaftar dan menunggu consent, grant
  /// tersimpan, serta event hook terakhir.
  Map<String, dynamic> pluginSnapshot() {
    final names = <String>{
      for (final p in plugins.plugins) p.name,
      for (final k in _pendingPlugins.keys) k,
    }.toList()..sort();
    final items = <Map<String, dynamic>>[
      for (final name in names)
        {
          'id': name,
          'registered': plugins.get(name) != null,
          'pending': _pendingPlugins.containsKey(name),
          'granted': pluginConsents.grantsOf(name).toList()..sort(),
          'requested': _pendingPlugins[name]?.permissions ?? const <String>[],
        },
    ];
    return {
      'plugins': items,
      'events': [
        for (final e in plugins.events.reversed.take(10))
          {
            'plugin': e.pluginName,
            'hook': e.hook.name,
            'detail': e.detail,
            'error': e.error?.toString(),
            'at': e.at.toIso8601String(),
          },
      ],
    };
  }

  /// Security Center snapshot (GUI-P1-10, read-only): konsolidasi status
  /// keamanan runtime — safe mode/panic, sandbox, state penyimpanan
  /// kredensial (tanpa nilai rahasia), consent plugin, token anomaly,
  /// anomali rate, guard counters, dan ringkasan audit terakhir.
  Map<String, dynamic> securitySnapshot() {
    final detector = _tokenAnomaly;
    final now = DateTime.now().toUtc();
    final day = now.toIso8601String().substring(0, 10);
    final pluginItems = pluginSnapshot()['plugins'] as List<dynamic>;
    final sealed = credentialManager.passphrase != null &&
        credentialManager.passphrase!.isNotEmpty;
    return {
      'safety': {
        'safe_mode': safety.safeMode,
        'panic': safety.panic,
        'stop_requested': safety.stopRequested,
      },
      'sandbox': sandboxKind.name,
      'credentials': {
        'sealed_storage': sealed,
      },
      'plugins': [
        for (final plugin in pluginItems)
          {
            'id': plugin['id'],
            'registered': plugin['registered'],
            'pending': plugin['pending'],
            'granted_count': (plugin['granted'] as List? ?? const []).length,
            'requested_count':
                (plugin['requested'] as List? ?? const []).length,
          },
      ],
      'token_anomaly': {
        'enabled': detector != null,
        'quarantines_today': _tokenQuarantinesByDay[day] ?? 0,
        'max_quarantines_per_day': config.tokenAnomaly.maxQuarantinesPerDay,
        'skills': [
          if (detector != null)
            for (final slug in detector.sampledSlugs) detector.statsFor(slug),
        ],
      },
      'rate_anomaly': {
        'window_sec': anomalyDetector.window.inSeconds,
        'max_events': anomalyDetector.maxEvents,
      },
      'guard': {
        'blocked_turns': _guardBlockedTurns,
        'sanitized_turns': _guardSanitizedTurns,
      },
      'audit': {
        'total_in_memory': audit.recent.length,
        'recent': [
          for (final entry in audit.recent.reversed.take(15))
            Map<String, dynamic>.from(entry),
        ],
      },
    };
  }

  /// Audit query browser (GUI-P1-11, read-only): filter entri audit dari
  /// buffer in-memory + file JSONL harian (menyimpan riwayat lintas
  /// restart, dedupe by serialisasi), urut terbaru dulu, paginate.
  Future<Map<String, dynamic>> auditQuery({
    String? tool,
    String? session,
    String? risk,
    String? verdict,
    bool? taint,
    DateTime? since,
    DateTime? until,
    int limit = 50,
    int offset = 0,
    int daysBack = 7,
  }) async {
    final toolLower = tool?.toLowerCase();
    final riskLower = risk?.toLowerCase();
    final verdictLower = verdict?.toLowerCase();
    final merged = <String, Map<String, dynamic>>{};
    void collect(Map<String, dynamic> entry) {
      final key = jsonEncode(entry);
      merged.putIfAbsent(key, () => Map<String, dynamic>.from(entry));
    }

    final dir = Directory(audit.directory);
    if (await dir.exists()) {
      final now = DateTime.now().toUtc();
      final files = <String>[];
      for (var i = 0; i < daysBack; i++) {
        final day = now.subtract(Duration(days: i)).toIso8601String();
        files.add('audit-${day.substring(0, 10).replaceAll('-', '')}.jsonl');
      }
      for (final name in files) {
        final file = File(p.join(dir.path, name));
        if (!await file.exists()) continue;
        try {
          for (final line in await file.readAsLines()) {
            if (line.trim().isEmpty) continue;
            try {
              collect(Map<String, dynamic>.from(
                  jsonDecode(line) as Map));
            } catch (_) {}
          }
        } catch (_) {} // best-effort: file corrupt/partial
      }
    }
    for (final entry in audit.recent) {
      collect(entry);
    }

    bool matches(Map<String, dynamic> entry) {
      final ts = DateTime.tryParse('${entry['ts']}');
      if (since != null && ts != null && ts.isBefore(since)) return false;
      if (until != null && ts != null && ts.isAfter(until)) return false;
      if (taint != null && (entry['taint'] == true) != taint) return false;
      if (session != null && '${entry['session']}' != session) return false;
      if (riskLower != null &&
          !'${entry['risk']}'.toLowerCase().contains(riskLower)) {
        return false;
      }
      if (verdictLower != null &&
          !'${entry['verdict']}'.toLowerCase().contains(verdictLower)) {
        return false;
      }
      if (toolLower != null &&
          !'${entry['tool']}'.toLowerCase().contains(toolLower)) {
        return false;
      }
      return true;
    }

    final matched = [
      for (final entry in merged.values)
        if (matches(entry)) entry,
    ]..sort((a, b) => '${b['ts']}'.compareTo('${a['ts']}'));
    final safeLimit = limit.clamp(1, 200);
    final safeOffset = offset < 0 ? 0 : offset;
    return {
      'entries': [
        for (var i = safeOffset;
            i < matched.length && i < safeOffset + safeLimit;
            i++)
          matched[i],
      ],
      'total': matched.length,
    };
  }

  static const _artifactSkipDirs = {
    '.git', 'build', '.dart_tool', 'node_modules', '.vibe', '__pycache__',
  };

  /// Artifacts browser (GUI-P2-04, read-only): daftar file di workspace
  /// (rekursif terbatas, skip direktori build/VC) — path relatif + ukuran
  /// + mtime. Path divalidasi PathSafety (symlink-aware, fail-closed).
  Map<String, dynamic> artifactsList({String sub = '', int limit = 200}) {
    final trimmed = sub.trim();
    final dirPath = trimmed.isEmpty
        ? workspace
        : PathSafety.resolveInRoot(workspace, trimmed);
    if (dirPath == null) {
      throw ArgumentError('path di luar workspace');
    }
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return {'files': const [], 'truncated': false};
    final files = <Map<String, dynamic>>[];
    var truncated = false;
    void walk(Directory d, String prefix) {
      if (truncated) return;
      final entities = d.listSync(followLinks: false)
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final entity in entities) {
        if (files.length >= limit) {
          truncated = true;
          return;
        }
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_artifactSkipDirs.contains(name)) continue;
          walk(entity, prefix.isEmpty ? name : '$prefix/$name');
        } else if (entity is File) {
          final stat = entity.statSync();
          files.add({
            'path': prefix.isEmpty ? name : '$prefix/$name',
            'bytes': stat.size,
            'modified': stat.modified.toUtc().toIso8601String(),
          });
        }
      }
    }

    walk(dir, '');
    return {'files': files, 'truncated': truncated};
  }

  /// Baca isi file teks dari workspace (GUI-P2-04, read-only, terpotong
  /// di [maxBytes]; file biner ditandai tanpa konten).
  Map<String, dynamic> artifactsRead(String path, {int maxBytes = 262144}) {
    final resolved = PathSafety.resolveInRoot(workspace, path.trim());
    if (resolved == null) throw ArgumentError('path di luar workspace');
    final file = File(resolved);
    if (!file.existsSync()) throw StateError('file tidak ditemukan');
    final stat = file.statSync();
    final bytes = file.readAsBytesSync();
    final probeLen = bytes.length < 8000 ? bytes.length : 8000;
    final binary =
        bytes.take(probeLen).contains(0) || _looksBinary(bytes.take(probeLen));
    if (binary) {
      return {
        'path': p.relative(resolved, from: workspace),
        'bytes': stat.size,
        'binary': true,
        'truncated': false,
        'bak_exists': _bakExists(path.trim()),
      };
    }
    final truncated = bytes.length > maxBytes;
    final slice = truncated ? bytes.take(maxBytes).toList() : bytes;
    return {
      'path': p.relative(resolved, from: workspace),
      'bytes': stat.size,
      'binary': false,
      'truncated': truncated,
      'content': utf8.decode(slice, allowMalformed: true),
      'bak_exists': _bakExists(path.trim()),
    };
  }

  bool _bakExists(String path) {
    final bak = PathSafety.resolveInRoot(workspace, '$path.bak');
    return bak != null && File(bak).existsSync();
  }

  /// Diffviewer (GUI-P2-04, read-only): bandingkan versi terakhir file
  /// (`.bak` yang ditulis write_file) dengan file sekarang. LCS line-diff
  /// tanpa dependency; hasil marker '='/'+'/'-' dengan batas entri.
  Map<String, dynamic> artifactsDiff(String path, {int maxEntries = 400}) {
    final trimmed = path.trim();
    final newResolved = PathSafety.resolveInRoot(workspace, trimmed);
    if (newResolved == null) throw ArgumentError('path di luar workspace');
    final newFile = File(newResolved);
    final newExists = newFile.existsSync();
    final oldResolved = PathSafety.resolveInRoot(workspace, '$trimmed.bak');
    final oldExists = oldResolved != null && File(oldResolved).existsSync();
    if (!newExists) {
      return {
        'path': trimmed,
        'old_exists': oldExists,
        'new_exists': false,
        'lines': const [],
        'truncated': false,
      };
    }
    final newLines = const LineSplitter().convert(
        utf8.decode(newFile.readAsBytesSync(), allowMalformed: true));
    final oldLines = oldExists
        ? const LineSplitter().convert(utf8.decode(
            File(oldResolved).readAsBytesSync(),
            allowMalformed: true))
        : const <String>[];
    final entries = <Map<String, dynamic>>[];
    var truncated = false;
    void add(String type, String text) {
      if (entries.length >= maxEntries) {
        truncated = true;
        return;
      }
      entries.add({'type': type, 'text': text});
    }

    // Trim prefix & suffix yang identik untuk mengecilkan DP.
    var start = 0;
    while (start < oldLines.length &&
        start < newLines.length &&
        oldLines[start] == newLines[start]) {
      start++;
    }
    var endOld = oldLines.length;
    var endNew = newLines.length;
    while (endOld > start &&
        endNew > start &&
        oldLines[endOld - 1] == newLines[endNew - 1]) {
      endOld--;
      endNew--;
    }
    for (var i = 0; i < start && !truncated; i++) {
      add('=', oldLines[i]);
    }
    final midOld = oldLines.sublist(start, endOld);
    final midNew = newLines.sublist(start, endNew);
    const dpLimit = 1200;
    final dpOk = midOld.length <= dpLimit && midNew.length <= dpLimit;
    if (dpOk) {
      final n = midOld.length;
      final m = midNew.length;
      final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
      for (var i = n - 1; i >= 0; i--) {
        for (var j = m - 1; j >= 0; j--) {
          lcs[i][j] = midOld[i] == midNew[j]
              ? lcs[i + 1][j + 1] + 1
              : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
        }
      }
      var i = 0;
      var j = 0;
      while ((i < n || j < m) && !truncated) {
        if (i < n && j < m && midOld[i] == midNew[j]) {
          add('=', midOld[i]);
          i++;
          j++;
        } else if (j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1])) {
          add('-', midOld[i]);
          i++;
        } else {
          add('+', midNew[j]);
          j++;
        }
      }
    } else {
      for (final line in midOld) {
        add('-', line);
      }
      for (final line in midNew) {
        add('+', line);
      }
    }
    for (var k = endOld; k < oldLines.length && !truncated; k++) {
      add('-', oldLines[k]);
    }
    for (var k = endNew; k < newLines.length && !truncated; k++) {
      add('+', newLines[k]);
    }
    return {
      'path': trimmed,
      'old_exists': oldExists,
      'new_exists': newExists,
      'lines': entries,
      'truncated': truncated,
    };
  }

  bool _looksBinary(Iterable<int> bytes) {
    var suspicious = 0;
    var count = 0;
    for (final b in bytes) {
      count++;
      if (b < 9 || (b > 13 && b < 32)) suspicious++;
    }
    return count > 0 && suspicious * 100 > count * 10;
  }

  /// Run-inspector (GUI-P2-04, read-only): snapshot turn aktif + riwayat
  /// terbaru ({active, recent, truncated}); input/answer sudah disanitasi
  /// [SecuritySanitizer] saat direkam, steps dibatasi per run.
  Map<String, dynamic> turnInspectorSnapshot({int limit = 40}) {
    return turnInspector.snapshot(maxRuns: limit);
  }

  String get _layeredMemoryPath => p.join(dataDir, 'layered_memory.json');

  /// Memory Explorer (GUI-P1-12, read): isi kurasi MEMORY.md/USER.md +
  /// anggaran karakter.
  Map<String, dynamic> memoryCuratedGet() => {
        'memory': {
          'text': curatedMemory.memoryText,
          'chars': curatedMemory.memoryText.length,
        },
        'user': {
          'text': curatedMemory.userText,
          'chars': curatedMemory.userText.length,
        },
        'budget': curatedMemory.charBudget,
        'used': curatedMemory.usedChars,
      };

  /// Memory Explorer (GUI-P1-12, write): ganti penuh satu file kurasi.
  /// Gagal (ArgumentError -> 400) bila gabungan kedua file melebihi anggaran.
  Future<Map<String, dynamic>> memoryCuratedSet({
    required String file,
    required String text,
  }) async {
    final isUser = file == 'user';
    if (!isUser && file != 'memory') {
      throw ArgumentError("file harus 'memory' atau 'user'");
    }
    final projected = curatedMemory.usedChars -
        (isUser
            ? curatedMemory.userText.length
            : curatedMemory.memoryText.length) +
        text.length;
    if (projected > curatedMemory.charBudget) {
      throw ArgumentError(
          'melebihi anggaran ${curatedMemory.charBudget} karakter (terproyeksi $projected)');
    }
    if (isUser) {
      curatedMemory.userText = text;
    } else {
      curatedMemory.memoryText = text;
    }
    await curatedMemory.save();
    return {
      'ok': true,
      'used': curatedMemory.usedChars,
      'budget': curatedMemory.charBudget,
    };
  }

  /// Memory Explorer (GUI-P1-12, read): entri berlapis. Dengan [query]
  /// memakai retrieval lintas lapis (skor x relevansi); tanpa query
  /// seluruh entri diurutkan terbaru dulu. Sertakan stats per lapisan.
  Map<String, dynamic> memoryLayersGet({String? query, int limit = 200}) {
    final capped = limit.clamp(1, 500);
    List<MemoryEntry> entries;
    if (query != null && query.trim().isNotEmpty) {
      entries = layeredMemory.retrieve(query.trim(), k: capped);
    } else {
      final all = layeredMemory.all.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      entries = all.take(capped).toList();
    }
    return {
      'stats': layeredMemory.stats(),
      'entries': [for (final e in entries) _layerEntryMap(e)],
      'total': layeredMemory.length,
      'truncated': layeredMemory.length > entries.length,
    };
  }

  Map<String, dynamic> _layerEntryMap(MemoryEntry e) {
    return {
      'id': e.id,
      'layer': e.layer.name,
      'text': e.text,
      'importance': e.importance,
      'tags': e.tags,
      'access_count': e.accessCount,
      'created_at': e.createdAt.toIso8601String(),
      'last_accessed_at': e.lastAccessedAt.toIso8601String(),
      'owner_key': e.ownerKey,
      'source_session': e.sourceSession,
    };
  }

  /// Memory Explorer (GUI-P1-12, write): tambah entri berlapis + persist.
  Future<Map<String, dynamic>> memoryLayerAdd({
    required String layer,
    required String text,
    double importance = 0.5,
    List<String> tags = const [],
    String? ownerKey,
    String? sourceSession,
  }) async {
    final matches = MemoryLayerType.values.where((t) => t.name == layer);
    if (matches.isEmpty) {
      throw ArgumentError('layer harus episodic/semantic/procedural');
    }
    if (text.trim().isEmpty) {
      throw ArgumentError('text wajib diisi');
    }
    final entry = layeredMemory.add(
      matches.first,
      text,
      importance: importance,
      tags: tags,
      ownerKey: ownerKey,
      sourceSession: sourceSession,
    );
    await layeredMemory.save(_layeredMemoryPath);
    return _layerEntryMap(entry);
  }

  /// Memory Explorer (GUI-P1-12, write): hapus entri berlapis + persist.
  /// StateError -> 404 bila id tidak ada.
  Future<bool> memoryLayerDelete(String id) async {
    final ok = layeredMemory.remove(id);
    if (!ok) throw StateError('entri berlapis tidak ditemukan: $id');
    await layeredMemory.save(_layeredMemoryPath);
    return true;
  }

  /// Memory Explorer (GUI-P1-12, read): sumber RAG dikelompokkan per
  /// dokumen (jumlah chunk + ukuran teks); read-only.
  Map<String, dynamic> memoryRagSources({int limit = 200}) {
    final capped = limit.clamp(1, 1000);
    final docs = <String, Map<String, dynamic>>{};
    for (final chunk in ragPipeline.chunks) {
      final doc = docs.putIfAbsent(chunk.docId, () => <String, dynamic>{
            'doc_id': chunk.docId,
            'chunks': 0,
            'chars': 0,
            'preview': '',
          });
      doc['chunks'] = (doc['chunks'] as int) + 1;
      doc['chars'] = (doc['chars'] as int) + chunk.text.length;
      if ((doc['preview'] as String).isEmpty) {
        doc['preview'] = chunk.text.trim().length > 120
            ? '${chunk.text.trim().substring(0, 120)}\u2026'
            : chunk.text.trim();
      }
    }
    final list = docs.values.toList()
      ..sort((a, b) => (b['chunks'] as int).compareTo(a['chunks'] as int));
    return {
      'chunk_count': ragPipeline.chunkCount,
      'docs': list.take(capped).toList(),
      'truncated': list.length > capped,
    };
  }

  /// Katalog tool terdaftar di registry host (GUI-P1-06, read-only):
  /// name/description/risk/timeout — paritas `/tools`.
  List<Map<String, dynamic>> toolCatalog() {
    final items = <Map<String, dynamic>>[
      for (final spec in registry.specs)
        {
          'name': spec.name,
          'description': spec.description,
          'risk': spec.risk,
          'timeout_sec': spec.timeoutSec,
          'parallel_safe': spec.parallelSafe,
        },
    ];
    items.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return items;
  }

  /// Status server MCP (GUI-P1-06, read-only): konfigurasi dari config
  /// immutable + hasil loader (ready/disabled/failed + jumlah tool).
  Map<String, dynamic> mcpSnapshot() => {
    'started': _mcpStarted,
    'configured': [
      for (final s in config.mcpServers)
        {
          'id': s.id,
          'type': s.type,
          'enabled': s.enabled,
          'risk': s.risk,
          'allow': s.allow,
          if (s.command != null) 'command': s.command,
        },
    ],
    'loader': mcpLoader.statuses,
  };

  /// Grant consent plugin (GUI-P1-06, paritas `/plugin consent <nama> grant`):
  /// simpan grant, registrasikan pending plugin, dan daftarkan tool
  /// deklarasinya. `ok == false` bila plugin tidak menunggu consent.
  Future<({bool ok, String message})> grantPluginConsent(String name) async {
    final id = name.trim().toLowerCase();
    final pending = _pendingPlugins[id];
    final requested = pending?.permissions ?? const <String>[];
    if (requested.isEmpty && !_pendingPlugins.containsKey(id)) {
      return (
        ok: false,
        message: 'Plugin "$id" tidak menunggu consent. '
            'Plugin pending: '
            '${_pendingPlugins.keys.isEmpty ? "-" : _pendingPlugins.keys.join(", ")}.',
      );
    }
    await pluginConsents.grant(id, requested);
    events.emit('plugin.consent.granted', {
      'plugin': id,
      'permissions': requested.toList(),
    });
    if (pending != null) {
      final ok = await plugins.register(
        pending.plugin,
        requestedPermissions: pending.permissions,
      );
      if (ok) {
        _pendingPlugins.remove(id);
        events.emit('plugin.registered', {'plugin': id});
        if (pending.plugin is ProcessPlugin) {
          await _registerPluginTools(
            pending.plugin as ProcessPlugin,
            pending.permissions,
          );
        }
        return (
          ok: true,
          message: 'Plugin "$id" disetujui dan terdaftar '
              '(${requested.join(", ")}).',
        );
      }
      return (
        ok: false,
        message: 'Consent "$id" tersimpan, tetapi registrasi gagal '
            '(lihat log plugin).',
      );
    }
    return (ok: true, message: 'Consent "$id" diperbarui.');
  }

  /// Revoke consent plugin (GUI-P1-06, paritas `/plugin consent <nama> revoke`):
  /// cabut semua grant dan batalkan registrasi plugin. `ok == false` bila
  /// plugin tidak dikenal.
  Future<({bool ok, String message})> revokePluginConsent(String name) async {
    final id = name.trim().toLowerCase();
    if (!pluginConsents.hasAnyGrant(id) &&
        !_pendingPlugins.containsKey(id) &&
        plugins.get(id) == null) {
      return (ok: false, message: 'Plugin "$id" tidak dikenal.');
    }
    await pluginConsents.revoke(id);
    await plugins.unregister(id);
    events.emit('plugin.consent.revoked', {'plugin': id});
    return (
      ok: true,
      message: 'Consent plugin "$id" dicabut; plugin dibatalkan registrasinya.',
    );
  }

  /// Registrasi plugin dengan capability consent (rekomendasi #5).
  /// Ditolak consent → masuk antrean pending + event `plugin.consent.required`.
  Future<bool> _registerPluginWithConsent(
    Plugin plugin,
    List<String> permissions,
  ) async {
    final ok = await plugins.register(plugin, requestedPermissions: permissions);
    if (ok) {
      _pendingPlugins.remove(plugin.name);
      events.emit('plugin.registered', {'plugin': plugin.name});
      return true;
    }
    _pendingPlugins[plugin.name] = _PendingPlugin(
      plugin: plugin,
      permissions: List<String>.unmodifiable(permissions),
    );
    events.emit('plugin.consent.required', {
      'plugin': plugin.name,
      'permissions': permissions,
    });
    return false;
  }

  /// B2: daftarkan tool yang dideklarasikan plugin out-of-process ke registry
  /// host. Hanya plugin dengan permission `tools.register` yang dijadwalkan
  /// (fail-closed); deklarasi tidak valid dilewati; kegagalan registrasi
  /// (mis. collision nama) dicatat sebagai event tanpa menggagalkan startup.
  Future<void> _registerPluginTools(
    ProcessPlugin plugin,
    List<String> permissions,
  ) async {
    final granted = permissions
        .map(PluginPermission.tryParse)
        .contains(PluginPermission.toolsRegister);
    if (!granted) return;
    try {
      final declared = await plugin.listTools();
      if (declared.isEmpty) return;
      registry.registerAll([
        for (final spec in declared) PluginTool(plugin: plugin, declared: spec),
      ]);
      events.emit('plugin.tools.registered', {
        'plugin': plugin.name,
        'tools': [for (final spec in declared) spec.name],
      });
    } catch (error) {
      events.emit('plugin.tools.register_failed', {
        'plugin': plugin.name,
        'error': error.toString(),
      });
    }
  }

  _PluginCommand? _parsePluginCommand(String text) {
    final trimmed = text.trim();
    if (!RegExp(r'^/plugin(?:\s|$)', caseSensitive: false).hasMatch(trimmed)) {
      return null;
    }
    final rest = trimmed.substring('/plugin'.length).trim();
    if (rest.isEmpty || rest == 'list') {
      return const _PluginCommand(sub: 'list');
    }
    final parts = rest.split(RegExp(r'\s+'));
    return _PluginCommand(
      sub: parts.first.toLowerCase(),
      id: parts.length > 1 ? parts[1].toLowerCase() : '',
      rest: parts.length > 2 ? parts[2].toLowerCase() : '',
    );
  }

  /// `/plugin` — status plugin + capability consent (rekomendasi #5).
  Future<ChatRunResult> _pluginCommand(_PluginCommand cmd) async {
    switch (cmd.sub) {
      case 'list':
        final registered = plugins.plugins.map((p) => p.name).toList()..sort();
        final pending = _pendingPlugins.keys.toList()..sort();
        final buf = StringBuffer(
            '${registered.length} plugin terdaftar, '
            '${pending.length} menunggu consent:\n');
        for (final name in registered) {
          buf.writeln('- $name [terdaftar, consent: '
              '${pluginConsents.grantsOf(name).isEmpty ? '-' : pluginConsents.grantsOf(name).join("+")}]');
        }
        for (final name in pending) {
          buf.writeln('- $name [menunggu consent: '
              '${_pendingPlugins[name]!.permissions.join(", ")}]');
        }
        buf.write('\nSetujui: /plugin consent <nama> grant · '
            'tarik: /plugin consent <nama> revoke');
        return ChatRunResult(text: buf.toString(), success: true);

      case 'info':
        final pending = _pendingPlugins[cmd.id];
        final registered = plugins.get(cmd.id);
        if (registered == null && pending == null) {
          return ChatRunResult(
            text: 'Plugin "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        final buf = StringBuffer('Plugin ${cmd.id}:\n'
            'status: ${registered != null ? 'terdaftar' : 'menunggu consent'}\n'
            'consent: ${pluginConsents.grantsOf(cmd.id).isEmpty ? '(kosong)' : pluginConsents.grantsOf(cmd.id).join(", ")}');
        if (pending != null) {
          buf.write('\npermission diminta: ${pending.permissions.join(", ")}');
        }
        return ChatRunResult(text: buf.toString(), success: true);

      case 'consent':
        if (cmd.id.isEmpty || cmd.rest.isEmpty) {
          return const ChatRunResult(
            text: 'Pemakaian: /plugin consent <nama> grant|revoke',
            success: false,
            retryable: true,
          );
        }
        if (cmd.rest == 'grant' || cmd.rest == 'revoke') {
          final result = cmd.rest == 'grant'
              ? await grantPluginConsent(cmd.id)
              : await revokePluginConsent(cmd.id);
          return ChatRunResult(
            text: result.message,
            success: result.ok,
            retryable: !result.ok,
          );
        }
        return ChatRunResult(
          text: 'Aksi consent tidak dikenal: ${cmd.rest}. '
              'Gunakan grant atau revoke.',
          success: false,
          retryable: true,
        );

      default:
        return ChatRunResult(
          text: 'Sub-perintah /plugin tidak dikenal: ${cmd.sub}. '
              'Gunakan: list, info, consent.',
          success: false,
          retryable: true,
        );
    }
  }

  _BotCommand? _parseBotCommand(String text) {
    final trimmed = text.trim();
    if (!RegExp(r'^/bot(?:\s|$)', caseSensitive: false).hasMatch(trimmed)) {
      return null;
    }
    final rest = trimmed.substring('/bot'.length).trim();
    if (rest.isEmpty || rest == 'list') {
      return const _BotCommand(sub: 'list');
    }
    final parts = rest.split(RegExp(r'\s+'));
    final sub = parts.first.toLowerCase();
    final id = parts.length > 1 ? parts[1].toLowerCase() : '';
    final tail = parts.length > 2
        ? trimmed.substring(trimmed.indexOf(parts[1]) + parts[1].length).trim()
        : '';
    final afterSub =
        trimmed.substring(trimmed.indexOf(parts.first) + parts.first.length)
            .trim();
    return _BotCommand(sub: sub, id: id, rest: tail, tail: afterSub);
  }

  /// Gate sesi bot: tool di luar allowlist bot ditolak langsung pada level
  /// eksekusi (bukan hanya disembunyikan dari prompt), sisanya diteruskan ke
  /// gate matriks biasa. Sesi tanpa bot memakai gate biasa.
  PermissionGate _botGate(BotProfile? bot) {
    final base = buildGate();
    if (bot == null) return base;
    if (bot.toolAllowlist.isEmpty) return base;
    return _BotToolGate(base, Set.of(bot.toolAllowlist));
  }

  /// `/bot` — Bot Mode: persona persisten per chat (Hermes-parity).
  Future<ChatRunResult> _botCommand(
    _BotCommand cmd, {
    required String sessionId,
  }) async {
    switch (cmd.sub) {
      case 'list':
        final bots = botStore.list();
        final active = botStore.boundBotId(sessionId);
        if (bots.isEmpty) {
          return const ChatRunResult(
            text: 'Belum ada bot. Buat: /bot new <id> <nama>\n'
                'Lalu atur persona: /bot persona <id> <deskripsi persona>\n'
                'Aktifkan di sesi ini: /bot use <id>',
            success: true,
          );
        }
        final buf = StringBuffer('Bot terdaftar (sesi ini: '
            '${active ?? 'tanpa bot'}):\n');
        for (final b in bots) {
          buf.writeln('- ${b.id} — "${b.name}"'
              '${b.model != null ? ' (model=${b.model})' : ''}'
              '${b.id == active ? ' [aktif]' : ''}');
        }
        buf.write('\nAktifkan: /bot use <id> · nonaktif: /bot off · '
            'detail: /bot show <id> · allowlist tool: /bot allow <id> <tool> '
            '· impor card: /bot import <path>');
        return ChatRunResult(text: buf.toString(), success: true);

      case 'new':
        if (cmd.id.isEmpty || cmd.rest.isEmpty) {
          return const ChatRunResult(
            text: 'Pemakaian: /bot new <id> <nama>. '
                'id: huruf kecil, angka, "-" atau "_".',
            success: false,
            retryable: true,
          );
        }
        if (!BotProfile.isValidId(cmd.id)) {
          return ChatRunResult(
            text: 'id bot "${cmd.id}" tidak valid — gunakan huruf kecil, '
                'angka, "-" atau "_" (maks 64 karakter).',
            success: false,
            retryable: true,
          );
        }
        if (botStore.get(cmd.id) != null) {
          return ChatRunResult(
            text: 'Bot "${cmd.id}" sudah ada. Lihat: /bot show ${cmd.id}',
            success: false,
            retryable: true,
          );
        }
        final name = cmd.rest.replaceAll('"', '').trim();
        await botStore.create(id: cmd.id, name: name);
        events.emit('bot.created', {'bot': cmd.id, 'session': sessionId});
        return ChatRunResult(
          text: 'Bot "${cmd.id}" ($name) dibuat. Tetapkan persona: '
              '/bot persona ${cmd.id} <deskripsi persona> · '
              'opsional model: /bot model ${cmd.id} <provider|default> · '
              'aktifkan: /bot use ${cmd.id}',
          success: true,
        );

      case 'persona':
        if (botStore.get(cmd.id) == null || cmd.rest.isEmpty) {
          return ChatRunResult(
            text: cmd.rest.isEmpty
                ? 'Pemakaian: /bot persona <id> <deskripsi persona>'
                : 'Bot "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        await botStore.update(cmd.id, (b) => b.copyWith(persona: cmd.rest));
        events.emit('bot.updated', {'bot': cmd.id, 'field': 'persona'});
        return ChatRunResult(
          text: 'Persona bot "${cmd.id}" diperbarui '
              '(${cmd.rest.length} karakter).',
          success: true,
        );

      case 'model':
        final bot = botStore.get(cmd.id);
        if (bot == null || cmd.rest.isEmpty) {
          return ChatRunResult(
            text: cmd.rest.isEmpty
                ? 'Pemakaian: /bot model <id> <provider|default>\n'
                    'Provider tersedia: ${_router.providers.keys.toList()..sort()} '
                    '(default: ${_router.defaultProviderId ?? '-'})'
                : 'Bot "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        final provider = cmd.rest.toLowerCase();
        if (provider == 'default') {
          await botStore.update(cmd.id, (b) => b.copyWith(clearModel: true));
          events.emit('bot.updated', {'bot': cmd.id, 'field': 'model'});
          return ChatRunResult(
            text: 'Bot "${cmd.id}" mengikuti provider default router.',
            success: true,
          );
        }
        if (!_router.providers.containsKey(provider)) {
          return ChatRunResult(
            text: 'Provider "$provider" tidak dikenal. Provider tersedia: '
                '${_router.providers.keys.join(", ")}.',
            success: false,
            retryable: true,
          );
        }
        await botStore.update(cmd.id, (b) => b.copyWith(model: provider));
        events.emit('bot.updated', {'bot': cmd.id, 'field': 'model'});
        return ChatRunResult(
          text: 'Bot "${cmd.id}" memakai provider: $provider',
          success: true,
        );

      case 'allow':
        final botAllow = botStore.get(cmd.id);
        if (botAllow == null || cmd.rest.isEmpty) {
          return ChatRunResult(
            text: cmd.rest.isEmpty
                ? 'Pemakaian: /bot allow <id> <tool1,tool2,...> | clear\n'
                    'Tool terdaftar: '
                    '${registry.specs.map((s) => s.name).toList()..sort()}'
                : 'Bot "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        if (cmd.rest.trim().toLowerCase() == 'clear') {
          await botStore.update(
            cmd.id,
            (b) => b.copyWith(clearToolAllowlist: true),
          );
          events.emit('bot.updated', {'bot': cmd.id, 'field': 'tool_allowlist'});
          return ChatRunResult(
            text: 'Allowlist bot "${cmd.id}" dikosongkan — sesi dengan bot '
                'ini ditolak fail-closed hingga allowlist diatur lagi.',
            success: true,
          );
        }
        final requested = cmd.rest
            .split(RegExp(r'[,\s]+'))
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toSet();
        final knownTools = registry.specs.map((s) => s.name).toSet();
        final unknown = requested.where((t) => !knownTools.contains(t)).toList();
        if (unknown.isNotEmpty) {
          return ChatRunResult(
            text: 'Tool tidak dikenal: ${unknown.join(', ')}. Tool terdaftar: '
                '${knownTools.toList()..sort()}.',
            success: false,
            retryable: true,
          );
        }
        final tools = requested.toList()..sort();
        await botStore.update(
          cmd.id,
          (b) => b.copyWith(toolAllowlist: tools),
        );
        events.emit('bot.updated', {'bot': cmd.id, 'field': 'tool_allowlist'});
        return ChatRunResult(
          text: 'Bot "${cmd.id}" hanya boleh memakai ${tools.length} tool: '
              '${tools.join(', ')}.',
          success: true,
        );

      case 'import':
        if (cmd.tail.isEmpty) {
          return const ChatRunResult(
            text: 'Pemakaian: /bot import <path-card.json|png>. '
                'Card harus berada di dalam workspace.',
            success: false,
            retryable: true,
          );
        }
        try {
          final card = await CharacterCardImporter.fromFile(
            cmd.tail,
            workspaceRoot: workspace,
          );
          final id = CharacterCardImporter.uniqueId(botStore, card.id);
          await botStore.create(
            id: id,
            name: card.name,
            persona: card.persona,
            greeting: card.greeting,
          );
          events.emit('bot.imported', {'bot': id, 'source': cmd.tail});
          return ChatRunResult(
            text: 'Bot "$id" diimpor dari character card "${card.name}". '
                'Allowlist tool masih kosong (fail-closed): izinkan tool '
                'dengan /bot allow $id <tool1,tool2> lalu aktifkan dengan '
                '/bot use $id.',
            success: true,
          );
        } on FormatException catch (e) {
          return ChatRunResult(
            text: 'Impor card gagal: ${e.message}',
            success: false,
            retryable: true,
          );
        } on ArgumentError catch (e) {
          return ChatRunResult(
            text: 'Impor card gagal: ${e.message}',
            success: false,
            retryable: true,
          );
        } on FileSystemException catch (e) {
          return ChatRunResult(
            text: 'Impor card gagal: ${e.message}',
            success: false,
            retryable: true,
          );
        }

      case 'use':
        if (botStore.get(cmd.id) == null) {
          return ChatRunResult(
            text: 'Bot "${cmd.id}" tidak dikenal. Bot terdaftar: '
                '${botStore.list().map((b) => b.id).join(', ').isEmpty ? '-' : botStore.list().map((b) => b.id).join(', ')}.',
            success: false,
            retryable: true,
          );
        }
        await botStore.bind(sessionId, cmd.id);
        events.emit('bot.activated', {'bot': cmd.id, 'session': sessionId});
        final bot = botStore.get(cmd.id)!;
        return ChatRunResult(
          text: 'Sesi ini memakai bot "${cmd.id}" (${bot.name}).'
              '${bot.greeting.isNotEmpty ? '\n${bot.greeting}' : ''}',
          success: true,
        );

      case 'off':
        final previous = botStore.boundBotId(sessionId);
        await botStore.unbind(sessionId);
        if (previous == null) {
          return const ChatRunResult(
            text: 'Sesi ini tidak sedang memakai bot.',
            success: true,
          );
        }
        events.emit('bot.deactivated', {'bot': previous, 'session': sessionId});
        return ChatRunResult(
          text: 'Bot "$previous" dinonaktifkan untuk sesi ini.',
          success: true,
        );

      case 'show':
        final bot = botStore.get(cmd.id);
        if (bot == null) {
          return ChatRunResult(
            text: 'Bot "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        final b = bot;
        final buf = StringBuffer('Bot ${b.id} — "${b.name}"\n'
            'model: ${b.model ?? 'default router'}\n'
            'dibuat: ${b.createdAt.toIso8601String()}\n'
            'tool allowlist: '
            '${b.toolAllowlist.isEmpty ? '(kosong — turn ditolak fail-closed)' : b.toolAllowlist.join(', ')}\n'
            'persona:\n${b.persona.isEmpty ? '(kosong)' : b.persona}');
        return ChatRunResult(text: buf.toString(), success: true);

      case 'delete':
        if (botStore.get(cmd.id) == null) {
          return ChatRunResult(
            text: 'Bot "${cmd.id}" tidak dikenal.',
            success: false,
            retryable: true,
          );
        }
        await botStore.delete(cmd.id);
        events.emit('bot.deleted', {'bot': cmd.id});
        return ChatRunResult(
          text: 'Bot "${cmd.id}" dihapus beserta binding sesinya.',
          success: true,
        );

      default:
        return ChatRunResult(
          text: 'Sub-perintah /bot tidak dikenal: ${cmd.sub}. '
              'Gunakan: list, new, persona, model, allow, import, use, off, show, '
              'delete.',
          success: false,
          retryable: true,
        );
    }
  }

  /// `/tools` — daftar tool registry + tingkat risikonya.
  ChatRunResult _toolsCommand() {
    final specs = registry.specs.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final buf = StringBuffer('${specs.length} tool terdaftar:\n');
    for (final s in specs) {
      buf.writeln('- ${s.name} (risk=${s.risk})');
    }
    return ChatRunResult(text: buf.toString(), success: true);
  }

  /// `/memory` — tampilkan isi memori terkurasi + pemakaian anggaran.
  ChatRunResult _curatedMemoryStatus() {
    final block = curatedMemory.snapshotPromptBlock();
    final text = curatedMemory.isEmpty
        ? 'Memori terkurasi kosong. Agent akan mengusulkan fakta durabel '
            'lewat nudge periodik, atau tambahkan manual di '
            '${curatedMemory.memoryPath}.'
        : '$block\n\nAnggaran: ${curatedMemory.usedChars}/'
            '${curatedMemory.charBudget} karakter\n'
            'MEMORY.md: ${curatedMemory.memoryPath}\n'
            'USER.md: ${curatedMemory.userPath}';
    return ChatRunResult(text: text, success: true);
  }

  /// E1 (opt-in): deteksi lonjakan token per skill. Total token giliran
  /// diatribusikan ke setiap skill yang dipakai giliran itu (bisa dobel
  /// hitung antar skill — pendekatan konservatif). Saat anomali terdeteksi:
  /// audit log + event `security.token_anomaly` + karantina skill ke draft
  /// (cap harian, skill draft/retired dilewati). Best-effort: tidak pernah
  /// menggagalkan giliran chat.
  Future<void> _checkTokenAnomaly(
    Session session,
    ChatRunResult result,
  ) async {
    final detector = _tokenAnomaly;
    if (detector == null || result.skillsUsed.isEmpty) return;
    if (result.tokensUsed <= 0) return;
    final now = DateTime.now().toUtc();
    final day = now.toIso8601String().substring(0, 10);
    for (final slug in result.skillsUsed) {
      final TokenAnomaly? anomaly;
      try {
        anomaly = detector.observe(slug, result.tokensUsed, now);
      } catch (_) {
        continue; // best-effort
      }
      if (anomaly == null) continue;

      final quarantined = _quarantineOnTokenAnomaly(slug, day);
      final detail = 'lonjakan token: ${anomaly.tokens} '
          '(baseline ${anomaly.baselineMean.toStringAsFixed(0)}, '
          'ambang ${anomaly.threshold.toStringAsFixed(0)}, '
          'sampel ${anomaly.samples})';
      events.emit('security.token_anomaly', {
        ...anomaly.toJson(),
        'session': session.id,
        'quarantined': quarantined,
      });
      try {
        await audit.log(
          sessionId: session.id,
          tool: 'token_anomaly',
          args: {'slug': slug},
          risk: 'medium',
          verdict: quarantined ? 'anomali-karantina' : 'anomali',
          resultSummary: detail,
        );
      } catch (_) {
        // Audit best-effort; jangan gagalkan giliran.
      }
    }
  }

  /// E1: karantina skill ke status draft bila anomali token terdeteksi.
  /// Konservatif: cap harian, skill draft/retired dilewati, dan skill
  /// harus ada di registry. Return true bila karantina dilakukan.
  bool _quarantineOnTokenAnomaly(String slug, String day) {
    final maxPerDay = config.tokenAnomaly.maxQuarantinesPerDay;
    if ((_tokenQuarantinesByDay[day] ?? 0) >= maxPerDay) return false;
    final skill = skills.get(slug);
    if (skill == null) return false;
    if (skill.status == SkillStatus.draft ||
        skill.status == SkillStatus.retired) {
      return false;
    }
    skill.status = SkillStatus.draft;
    skill.approvedBy = null;
    _tokenQuarantinesByDay[day] = (_tokenQuarantinesByDay[day] ?? 0) + 1;
    try {
      reflectionEngine?.recordCorrectiveLesson(
        trigger: 'skill $slug lonjakan token anomali',
        insight: 'skill $slug memakai token jauh di atas baseline '
            'historisnya — periksa apakah prompt/argumennya membengkak',
        action: 'tinjau skill sebelum dipromosikan ulang',
        sessionId: 'token-anomaly',
      );
    } catch (_) {
      // best-effort
    }
    return true;
  }

  /// E2 (opt-in): jalankan konsolidasi memori idle (best-effort). Dipicu
  /// setelah giliran chat saat ambang idle tercapai. Saat fakta baru
  /// dihasilkan: event `memory.idle_consolidated` + AuditLog + persist
  /// layered memory segera (tidak menunggu shutdown).
  Future<IdleConsolidationReport?> _runIdleConsolidation(
    String sessionId,
  ) async {
    final consolidator = _idleConsolidator;
    if (consolidator == null) return null;
    final IdleConsolidationReport? report;
    try {
      report = await consolidator.noteTurn();
    } catch (_) {
      return null; // best-effort
    }
    if (report == null || report.factsAdded == 0) return report;
    try {
      await layeredMemory.save(p.join(dataDir, 'layered_memory.json'));
    } catch (_) {
      // Persist best-effort; memori tetap di memori sampai shutdown.
    }
    try {
      await audit.log(
        sessionId: sessionId,
        tool: 'idle_consolidation',
        args: const {},
        risk: 'low',
        verdict: 'ok',
        resultSummary:
            '${report.factsAdded} fakta semantik dari ${report.candidates} '
            'entri episodik',
      );
    } catch (_) {
      // Audit best-effort.
    }
    return report;
  }

  /// E2 (khusus test): akses konsolidator untuk verifikasi wiring.
  // ignore: avoid_public_member_api_docs
  IdleMemoryConsolidator? get idleConsolidatorForTest => _idleConsolidator;

  /// E2 (khusus test): panggil pass konsolidasi idle secara langsung.
  Future<IdleConsolidationReport?> runIdleConsolidationForTest(
    String sessionId,
  ) =>
      _runIdleConsolidation(sessionId);

  /// E1 (khusus test): akses detektor untuk verifikasi wiring.
  // ignore: avoid_public_member_api_docs
  TokenAnomalyDetector? get tokenAnomalyDetectorForTest => _tokenAnomaly;

  /// E1 (khusus test): jalankan pemeriksaan anomali token secara langsung
  /// tanpa harus melewati giliran chat penuh.
  Future<void> checkTokenAnomalyForTest(
    Session session,
    ChatRunResult result,
  ) => _checkTokenAnomaly(session, result);

  /// Closed learning loop (P1-8): after every turn, offer the trajectory to
  /// the [SelfLearningEngine] so a successful multi-tool workflow can be
  /// captured as a reusable skill file. Failures never break the chat turn.
  Future<void> _learnOnTurn({
    required Session session,
    required String userText,
    required String assistantText,
    required bool success,
    required List<ToolCallTrace> traces,
    required int tokensUsed,
  }) async {
    final engine = selfLearningEngine;
    try {
      selfEvolution?.recordTurn(
        sessionId: session.id,
        success: success,
        toolNames: [for (final t in traces) t.name],
        errorCount: traces.where((t) => t.isError).length,
        task: userText,
      );
    } catch (_) {
      // Evolution bookkeeping is best-effort; never fail the turn.
    }
    if (engine == null || traces.isEmpty) return;
    try {
      final calls = [
        for (final trace in traces)
          ToolCall(
            id: '',
            name: trace.name,
            args: _sanitizer.sanitizeArgs(trace.args),
          ),
      ];
      final result = await engine.processTurn(
        session: session,
        turn: ConversationTurn(
          userMessage: userText,
          assistantMessage: assistantText,
          isSuccessful: success,
          toolCalls: calls,
          tokensUsed: tokensUsed,
        ),
        toolCalls: calls,
        tokensUsed: tokensUsed,
      );
      if (result != null && result.success && result.skill != null) {
        events.emit('skill.synthesized', {
          'slug': result.skill!.slug,
          'score': result.score,
          'session': session.id,
        });
      }
    } catch (_) {
      // Learning is best-effort; a synthesis failure must not fail the turn.
    }
  }

  /// Appends the turn to the session reflection buffer and runs the
  /// reflection stage once enough turns accumulate (self-improving loop,
  /// reflection stage). Failures never break the chat turn.
  Future<void> _reflectOnTurn({
    required String sessionId,
    required String userText,
    required String assistantText,
    required bool success,
  }) async {
    final reflection = reflectionEngine;
    if (reflection == null || _closed) return;
    final turns = _reflectionTurns.putIfAbsent(sessionId, () => []);
    turns.add(ConversationTurn(
      userMessage: userText,
      assistantMessage: assistantText,
      isSuccessful: success,
    ));
    if (turns.length < reflection.config.minTurnsForReflection) return;
    final result = reflection.reflect(
      turns: List.of(turns),
      sessionId: sessionId,
    );
    turns.clear();
    try {
      await reflection.save();
    } catch (e) {
      stderr.writeln('runtime: reflection.save gagal: $e');
    }
    if (result.newLessons.isNotEmpty) {
      events.emit('reflection.lessons', {
        'session': sessionId,
        'count': result.newLessons.length,
      });
    }
  }

  /// Runs one nested subagent turn (ALG-04, P1-09). The child gets its own
  /// session - and therefore its own budget and lock - while inheriting
  /// the parent's channel and user key; the depth marker keeps nested
  /// spawn_subagent calls within the tool's max nesting depth.
  /// 
  /// Subagent execution respects budget limits and permission isolation.
  Future<SubagentResult> _runSubagent({
    required String goal,
    required String context,
    required Session parent,
    required int depth,
    required SubagentBudget budget,
    required Set<String> allowedTools,
  }) async {
    if (_closed) throw StateError('runtime is closed');
    
    final subagentId = '${parent.id}/sub/$depth/${DateTime.now().microsecondsSinceEpoch}';
    final startTime = DateTime.now();
    
    final child = await sessions.getOrCreate(
      subagentId,
      channel: parent.channel,
      userKey: parent.userKey,
    );
    SpawnSubagentTool.setDepth(child, depth);
    
    // P1-09: real isolation — non-empty allowlist is enforced by gate.
    // Empty allowlist inherits parent surface (full buildGate).
    final PermissionGate? isolationGate = allowedTools.isEmpty
        ? null
        : _EvalToolGate(allowedTools);
    final subConfig = AgentConfig(
      maxIterations: config.maxIterations,
      maxTokensPerTask: budget.maxTokens,
      maxWallClockSec: budget.maxTimeSeconds,
      maxToolCalls: budget.maxToolCalls,
    );

    final prompt = context.isEmpty ? goal : '$goal\n\nKonteks: $context';

    // Track execution metrics
    int tokenCount = 0;
    int toolCallCount = 0;
    final double cost = 0.0;

    try {
      final outcome = await chatWithStatus(
        prompt,
        sessionId: subagentId,
        channel: parent.channel,
        userKey: parent.userKey,
        gateOverride: isolationGate,
        configOverride: subConfig,
        toolFilter: allowedTools.isEmpty ? null : allowedTools,
      );
      
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      final timeSeconds = duration.inMilliseconds / 1000.0;
      
      tokenCount = outcome.tokensUsed;
      toolCallCount = outcome.toolCallCount;
      
      if (outcome.success) {
        return SubagentResult(
          success: true,
          output: outcome.text,
          subagentId: subagentId,
          parentId: parent.id,
          startedAt: startTime,
          completedAt: endTime,
          tokenCount: tokenCount,
          timeSeconds: timeSeconds,
          toolCallCount: toolCallCount,
          cost: cost,
        );
      } else {
        return SubagentResult(
          success: false,
          output: outcome.text,
          error: 'Subagent gagal: ${outcome.text}',
          subagentId: subagentId,
          parentId: parent.id,
          startedAt: startTime,
          completedAt: endTime,
          tokenCount: tokenCount,
          timeSeconds: timeSeconds,
          toolCallCount: toolCallCount,
          cost: cost,
        );
      }
    } catch (e) {
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      final timeSeconds = duration.inMilliseconds / 1000.0;
      
      return SubagentResult(
        success: false,
        output: '',
        error: 'Subagent error: $e',
        subagentId: subagentId,
        parentId: parent.id,
        startedAt: startTime,
        completedAt: endTime,
        tokenCount: tokenCount,
        timeSeconds: timeSeconds,
        toolCallCount: toolCallCount,
        cost: cost,
      );
    }
  }
  /// Start configured MCP child processes after the daemon owns its instance
  /// lock. Creating a runtime/CLI client never launches extension processes.
  Future<int> startMcp() async {
    if (_closed) throw StateError('runtime is closed');
    if (_mcpStarted) return 0;
    _mcpStarted = true;
    final servers = <Map<String, dynamic>>[];
    for (final server in config.mcpServers) {
      final resolvedEnvironment = <String, String>{};
      var missingSecret = false;
      for (final entry in server.environmentRefs.entries) {
        final value = TikoConfig.resolveSecretRef(entry.value, env: mcpEnvironment);
        if (value == null) {
          missingSecret = true;
        } else {
          resolvedEnvironment[entry.key] = value;
        }
      }
      final resolvedHeaders = <String, String>{};
      for (final entry in server.headerRefs.entries) {
        final value = TikoConfig.resolveSecretRef(entry.value, env: mcpEnvironment);
        if (value == null) {
          missingSecret = true;
        } else {
          resolvedHeaders[entry.key] = value;
        }
      }
      Map<String, dynamic>? resolvedOauth;
      if (server.hasOauth) {
        final secret = TikoConfig.resolveSecretRef(
          server.oauthClientSecretRef!,
          env: mcpEnvironment,
        );
        if (secret == null) {
          missingSecret = true;
        } else {
          resolvedOauth = {
            'token_url': server.oauthTokenUrl,
            'client_id': server.oauthClientId,
            'client_secret': secret,
            if (server.oauthScopes.isNotEmpty) 'scopes': server.oauthScopes,
          };
        }
      }
      servers.add({
        'id': server.id,
        'type': server.type,
        if (server.type == 'http') 'url': server.url,
        if (server.type == 'http') 'protocol_version': server.protocolVersion,
        if (server.type == 'http') 'max_read_retries': server.maxReadRetries,
        if (server.type == 'http')
          'allow_private_network': server.allowPrivateNetwork,
        if (server.type == 'stdio') 'command': server.command,
        'args': server.args,
        'allow': server.allow,
        'risk': server.risk,
        'enabled': server.enabled && !missingSecret,
        if (missingSecret) 'disabled_reason': 'one or more MCP SecretRefs are unset',
        'environment': resolvedEnvironment,
        'headers': resolvedHeaders,
        if (resolvedOauth != null) 'oauth': resolvedOauth,
      });
    }
    return mcpLoader.loadServers(servers);
  }

  /// Start the single runtime-owned scheduler. Dengan [deliver], giliran
  /// agent yang sukses mengantre outputnya untuk delivery gateway yang
  /// durabel: run hanya di-ack setelah sink mengonfirmasi delivery, gagal
  /// di-retry dengan backoff, dan `job.delivery_failed` diterbitkan bila
  /// retry habis. Tanpa [deliver], run selesai begitu giliran agent sukses
  /// (kontrak lama). Host hanya boleh mengirim ke channel milik job itu
  /// sendiri dan tidak pernah fallback ke gateway lain.
  void startScheduler({
    Duration tickInterval = const Duration(seconds: 20),
    DeliveryHandler? deliver,
  }) {
    if (_closed || _scheduler != null) return;
    _scheduler = Scheduler(
      store: jobs,
      tickInterval: tickInterval,
      duplicatePolicy: config.schedulerDuplicatePolicy == 'review'
          ? DeliveryDuplicatePolicy.review
          : DeliveryDuplicatePolicy.resend,
      onJob: (message, job) async {
        events.emit('job.started', {
          'job_id': job.id,
          'channel': job.channel,
          'session_id': message.sessionKey,
          'scheduled_at': job.scheduledAt?.toIso8601String(),
        });
        try {
          // Fase D — job riset (prompt ber-prefix [RISET]): jalankan
          // pipeline riset penuh, bukan turn chat biasa. Digest dikirim
          // via channel milik job; laporan markdown tetap tersimpan.
          if (isResearchJobPrompt(message.text)) {
            final record = await runResearch(
              question: researchQuestionFromPrompt(message.text),
              jobId: job.id,
            );
            if (record.status != 'ok') {
              throw StateError(
                record.error ?? 'pipeline riset tidak menghasilkan laporan',
              );
            }
            jobs.recordSuccess(job.id);
            if (deliver != null) {
              await jobs.awaitDelivery(
                job.id,
                message.meta['run_id'] as String? ?? '',
                '${record.summary}\n\n'
                    'Laporan lengkap: data/research/reports/${record.reportName}',
              );
            }
            events.emit('job.completed', {
              'job_id': job.id,
              'channel': job.channel,
              'user_key': job.userKey,
              'session_id': message.sessionKey,
              'kind': 'research',
              'run_id': record.runId,
              'run': record.toJson(),
              'text': record.summary,
              'scheduled_at': job.scheduledAt?.toIso8601String(),
              'delivery_pending': deliver != null,
            });
            return;
          }
          // Attach skill (Hermes-parity P2): fail-closed — skill hilang/
          // retired membuat run gagal dengan pesan eksplisit, bukan
          // dijalankan tanpa skill.
          var promptText = message.text;
          final attachedSkill =
              job.skill == null ? null : skills.get(job.skill!);
          if (job.skill != null &&
              (attachedSkill == null ||
                  attachedSkill.status == SkillStatus.retired)) {
            throw StateError(
              'skill "${job.skill}" tidak tersedia atau sudah retired',
            );
          }
          if (attachedSkill != null) {
            promptText =
                '${attachedSkill.body}\n\nTask:\n${message.text}';
          }
          final outcome = await chatWithStatus(
            promptText,
            sessionId: message.sessionKey,
            channel: job.channel,
            userKey: job.userKey,
          );
          if (attachedSkill != null) {
            skills.recordUse(attachedSkill.slug, success: outcome.success);
          }
          if (!outcome.success) {
            throw StateError(
              'scheduled agent turn did not complete successfully: ${outcome.text}',
            );
          }
          jobs.recordSuccess(job.id);
          if (deliver != null) {
            // Antre durabel sebelum menerbitkan sukses: crash setelah titik
            // ini me-replay delivery alih-alih kehilangan output.
            await jobs.awaitDelivery(
              job.id,
              message.meta['run_id'] as String? ?? '',
              outcome.text,
            );
          }
          events.emit('job.completed', {
            'job_id': job.id,
            'channel': job.channel,
            'user_key': job.userKey,
            'session_id': message.sessionKey,
            'text': outcome.text,
            'scheduled_at': job.scheduledAt?.toIso8601String(),
            'delivery_pending': deliver != null,
          });
        } catch (error) {
          jobs.recordFailure(job.id, _sanitizer.output('$error'));
          events.emit('job.failed', {
            'job_id': job.id,
            'marker': '[CRON_FAILURE]',
            'channel': job.channel,
            'session_id': message.sessionKey,
            'error': _sanitizer.output('$error'),
          });
          rethrow;
        }
      },
      deliver: deliver,
      onDelivered: (job, runId, attempts) => events.emit('job.delivered', {
        'job_id': job.id,
        'channel': job.channel,
        'run_id': runId,
        'attempts': attempts,
      }),
      onDeliveryRetry: (job, runId, attempt, error) =>
          events.emit('job.delivery_retry', {
        'job_id': job.id,
        'channel': job.channel,
        'run_id': runId,
        'attempt': attempt,
        'error': _sanitizer.output('$error'),
      }),
      onDeliveryFailed: (job, runId, attempts, error) {
        jobs.recordFailure(job.id, _sanitizer.output('$error'));
        events.emit('job.delivery_failed', {
          'job_id': job.id,
          'marker': '[CRON_FAILURE]',
          'channel': job.channel,
          'run_id': runId,
          'attempts': attempts,
          'error': _sanitizer.output('$error'),
          'session_id': '${job.channel}:${job.userKey}:job:${job.id}',
        });
      },
      onError: (job, error) => events.emit('job.retry', {
        'job_id': job.id,
        'channel': job.channel,
        'error': _sanitizer.output('$error'),
      }),
    )..start();
    events.emit('scheduler.started', {
      'jobs': jobs.all.length,
      'delivery_tracking': deliver != null,
    });
  }

  Future<void> stopScheduler() async {
    final scheduler = _scheduler;
    _scheduler = null;
    await scheduler?.shutdown();
    events.emit('scheduler.stopped');
  }

  /// Idempotent lifecycle shutdown shared by daemon and embedded callers.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final scheduler = _scheduler;
    _scheduler = null;
    try {
      await selfLearningEngine?.stop();
    } catch (_) {} // best-effort
    try {
      await selfEvolution?.stop();
    } catch (_) {}
    try {
      await layeredMemory.save(p.join(dataDir, 'layered_memory.json'));
    } catch (e) {
      stderr.writeln('runtime: shutdown layeredMemory.save gagal: $e');
    }
    try {
      await ragPipeline.lexical.save();
    } catch (e) {
      stderr.writeln('runtime: shutdown lexical.save gagal: $e');
    }
    try {
      await reflectionEngine?.save();
    } catch (e) {
      stderr.writeln('runtime: shutdown reflectionEngine.save gagal: $e');
    }
    try {
      await plugins.disposeAll();
    } catch (_) {} // best-effort
    try {
      await hookExecutor?.dispose();
    } catch (_) {} // best-effort
    try {
      // Feedback/metric sink writes are tracked, not fire-and-forget, so the
      // last 👍/👎 and use events survive a graceful shutdown.
      await skills.flushPendingSinks();
    } catch (e) {
      stderr.writeln('runtime: shutdown skills.flushPendingSinks gagal: $e');
    }
    try {
      cancellations.cancelAll();
    } catch (_) {} // best-effort
    try {
      await spans.close();
    } catch (e) {
      stderr.writeln('runtime: shutdown spans.close gagal: $e');
    }
    try {
      await approvals.close();
    } catch (e) {
      stderr.writeln('runtime: shutdown approvals.close gagal: $e');
    }
    try {
      await scheduler?.shutdown();
    } catch (_) {} // best-effort
    try {
      await mcpLoader.closeAll();
    } catch (_) {} // best-effort
    try {
      await scriptRunner.close();
    } catch (_) {} // best-effort
    try {
      await smartHomeTool?.close();
    } catch (_) {} // best-effort
    try {
      await _sandbox?.dispose();
    } catch (_) {} // best-effort
    try {
      if (_baseMemory is SafeMemoryStore) {
        final inner = (_baseMemory as SafeMemoryStore).inner;
        if (inner is SqliteMemoryStore) inner.close();
      } else if (_baseMemory is SqliteMemoryStore) {
        (_baseMemory as SqliteMemoryStore).close();
      }
    } catch (_) {} // best-effort
    await events.close();
  }

  /// All external surfaces decide the same persisted approval request.
  Future<ApprovalRequest?> decideApproval(
    String id, {
    required bool approve,
    String actor = 'api',
    String? reason,
  }) async {
    final request = await approvals.decide(
      id,
      approve: approve,
      actor: actor,
      reason: reason,
    );
    if (request != null) {
      events.emit('approval.decided', request.toJson());
    }
    return request;
  }
}

/// Parses the W3C `OTEL_EXPORTER_OTLP_HEADERS` format: `key1=value1,key2=value2`.
Map<String, String> _parseOtelHeaders(String raw) {
  final headers = <String, String>{};
  for (final pair in raw.split(',')) {
    final idx = pair.indexOf('=');
    if (idx <= 0) continue;
    final key = pair.substring(0, idx).trim();
    final value = pair.substring(idx + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
  }
  return headers;
}

class _ModelCommand {
  const _ModelCommand({required this.arg});
  final String arg;
}

class _BotToolGate implements PermissionGate {
  _BotToolGate(this.inner, this.allowlist);

  final PermissionGate inner;
  final Set<String> allowlist;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (!allowlist.contains(call.name)) {
      return PermissionResult(
        PermissionVerdict.denied,
        reason: 'tool "${call.name}" di luar allowlist bot',
      );
    }
    return inner.check(call, session);
  }
}

class _BotCommand {
  const _BotCommand({
    required this.sub,
    this.id = '',
    this.rest = '',
    this.tail = '',
  });
  final String sub;
  final String id;
  final String rest;

  /// Teks asli (tanpa lowercase) setelah sub — dipakai sub-perintah yang
  /// argumennya bukan id bot, mis. path file pada `/bot import`.
  final String tail;
}

class _PluginCommand {
  const _PluginCommand({required this.sub, this.id = '', this.rest = ''});
  final String sub;
  final String id;
  final String rest;
}

class _PendingPlugin {
  const _PendingPlugin({required this.plugin, required this.permissions});
  final Plugin plugin;
  final List<String> permissions;
}
