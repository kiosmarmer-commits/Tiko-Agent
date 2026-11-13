import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_security/agent_security.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;

import 'provider_factory.dart';
import 'runtime_lock.dart';
import 'tiko_config.dart';
import 'capability.dart';
import 'event_bus.dart';
import 'approval_ledger.dart';
import 'resource_monitor.dart';
import 'offline_queue.dart';
import 'reflection_loop.dart';
import 'kanban_board.dart';
import 'self_learning_engine.dart';
import 'team_tool.dart';

part 'tiko_runtime_internals.dart';

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
    required this.ragPipeline,
    this.reflectionEngine,
    this.personaPrompt,
    SelfLearningEngine? selfLearningEngine,
    SandboxRunner? sandbox,
  })  : _sandbox = sandbox,
        selfLearningEngine = selfLearningEngine ??
          (providers.isEmpty
              ? null
              : SelfLearningEngine(
                  llmProvider: providers.values.first,
                  skillRegistry: skills,
                  memoryStore: memory,
                  sessionStore: sessions,
                  skillsDir: skillsRoot,
                  config: const SelfLearningConfig(),
                ));

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
  final AuditLog audit;
  final String workspace;
  final String dataDir;
  final SkillRegistry skills;

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
  final SelfLearningEngine? selfLearningEngine;

  /// Content-plane guard (prompt injection + secret/PII output redaction).
  final PromptGuard promptGuard;

  /// Sliding-window rate anomaly detector keyed by user.
  final AnomalyDetector anomalyDetector;

  /// Hermes-style plugin registry; hooks dispatch through the permission
  /// gate and chat lifecycle.
  final PluginRegistry plugins;

  /// Layered memory (episodic/semantic/procedural) with decay.
  final LayeredMemory layeredMemory;

  /// Hybrid RAG pipeline (dense + BM25 + RRF) shared with the vector index.
  final RagPipeline ragPipeline;

  /// Reflection stage of the self-improving loop; null when disabled.
  final ReflectionEngine? reflectionEngine;

  /// Immutable workspace persona (SOUL.md); null when the file is absent.
  final String? personaPrompt;

  /// Per-session turns accumulated for the reflection stage.
  final Map<String, List<ConversationTurn>> _reflectionTurns = {};
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

  /// Cooperative cancellation registry keyed by session id (P1-11). One live
  /// token per running turn; subagent turns chain to their parent's token so
  /// cancelling a parent session also stops its nested subagents.
  final CancellationRegistry cancellations = CancellationRegistry();
  final CapabilityVault capabilities;
  final EventBus events = EventBus();
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

    final factory = ProviderFactory(env: env);
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
        (env ?? Platform.environment)['TIKO_FORCE_JSON_MEMORY'] == '1';
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

    final externalProviders = [
      for (final c in cfg.memoryProviders)
        switch (c.kind) {
          'mem0' => Mem0MemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: env) ?? '',
              userId: c.name,
              baseUrl: c.baseUrl.isEmpty ? 'https://api.mem0.ai' : c.baseUrl,
            ),
          'honcho' => HonchoMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: env) ?? '',
              sessionId: c.name ?? 'tiko-agent',
              baseUrl: c.baseUrl.isEmpty ? 'https://api.honcho.dev' : c.baseUrl,
            ),
          'supermemory' => SupermemoryMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: env) ?? '',
              userId: c.name,
              baseUrl:
                  c.baseUrl.isEmpty ? 'https://api.supermemory.ai' : c.baseUrl,
            ),
          'hindsight' => HindsightMemoryProvider(
              apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: env) ?? '',
              userId: c.name,
              baseUrl: c.baseUrl,
            ),
          _ => HttpMemoryProvider(
              config: HttpMemoryProviderConfig(
                baseUrl: c.baseUrl,
                apiKey: TikoConfig.resolveSecretRef(c.apiKeyRef, env: env),
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
    final plugins = PluginRegistry();

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
      final falKey = TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: env);
      if (falKey != null && falKey.isNotEmpty) {
        imageProviders['fal'] = FalAiImageProvider(apiKey: falKey);
      }
      final openaiKey = TikoConfig.resolveSecretRef(cfg.openaiApiKeyRef, env: env);
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
      final falKey = TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: env);
      if (falKey != null && falKey.isNotEmpty) {
        videoRouter = FalVideoGenerationProvider(apiKey: falKey);
      }
    }

    final sessionStore = FileSessionStore(path: p.join(dataDir, 'sessions.json'));

    final registry = ToolRegistry()
      ..registerAll(createBuiltinTools(
        workspaceRoot: workspace,
        searxngBaseUrl: cfg.searxngBaseUrl,
        tavilyApiKey: TikoConfig.resolveSecretRef(cfg.tavilyApiKeyRef, env: env),
        sandbox: sandbox,
        skillRegistry: skillRegistry,
        falApiKey: TikoConfig.resolveSecretRef(cfg.falApiKeyRef, env: env),
        openaiApiKey: TikoConfig.resolveSecretRef(cfg.openaiApiKeyRef, env: env),
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
    final mcpLoader = McpToolLoader(registry, sandbox: sandbox);

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
      mcpEnvironment: env ?? Platform.environment,
      decision: decision,
      tirith: tirith,
      capabilities: capabilityGate,
      credentialManager: credentialManager,
      fallbackManager: fallbackManager,
      promptGuard: promptGuard,
      anomalyDetector: anomalyDetector,
      plugins: plugins,
      layeredMemory: layeredMemory,
      ragPipeline: rag,
      reflectionEngine: reflection,
      personaPrompt: personaPrompt,
      selfLearningEngine: selfLearningEngine,
    );
    rt.approvals = ApprovalBroker(p.join(dataDir, 'approvals.json'));
    await rt.approvals.load();
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
    final otelEnv = env ?? Platform.environment;
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
    final envMap = env ?? Platform.environment;
    final hubUrl = envMap['TIKO_SKILLS_HUB_URL']?.trim() ?? '';
    if (hubUrl.isNotEmpty && rt.registry.get('skills_hub') == null) {
      rt.registry.register(SkillsHubTool(SkillsHubClient(
        config: SkillsHubConfig(
          apiBaseUrl: hubUrl,
          skillsDirectory: p.join(workspace, 'skills'),
          apiKey: envMap['TIKO_SKILLS_HUB_TOKEN']?.trim().isNotEmpty == true
              ? envMap['TIKO_SKILLS_HUB_TOKEN']!.trim()
              : null,
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
    // ALG-04: the agent-team tool only works with a runner that executes a
    // nested runtime turn per team member.
    if (rt.registry.get('agent_team') == null) {
      rt.registry.register(AgentTeamTool(
        runner: (prompt, agent) async {
          final eco = rt.resourceProfile == 'eco';
          final outcome = await rt.chatWithStatus(
            prompt,
            sessionId:
                'team:${agent.id}:${DateTime.now().microsecondsSinceEpoch}',
            channel: 'team',
            userKey: 'team',
            // Role isolation is enforced for real: an allowlisted member
            // never sees tools outside its list, and each role runs on its
            // own iteration budget (maxTurns) and model tier (modelTier)
            // instead of the host defaults.
            toolFilter:
                agent.toolAllowlist.isEmpty ? null : Set.of(agent.toolAllowlist),
            configOverride: AgentConfig(
              maxIterations: agent.maxTurns,
              maxTokensPerTask:
                  eco ? 20000 : cfg.maxTokensPerTask,
              maxWallClockSec: eco ? 120 : cfg.maxWallClockSec,
              maxToolCalls: eco ? 12 : cfg.maxToolCalls,
              preferredTier: modelTierToRouterTier(agent.modelTier),
            ),
          );
          return outcome.text;
        },
      ));
    }
    final snap = ResourceMonitor.capture(dataDir: dataDir);
    rt.lastResources = snap;
    rt.resourceProfile = snap.profile;
    
    // Start the self-learning engine for autonomous skill creation and improvement
    await rt.selfLearningEngine?.start();
    
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
  }) async => (await chatWithStatus(
        text,
        sessionId: sessionId,
        channel: channel,
        userKey: userKey,
        confirm: confirm,
        onTextDelta: onTextDelta,
      )).text;

  /// One agent turn with explicit completion status for durable queues/jobs.
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
  }) async {
    if (!_lock.tryAcquire(sessionId)) {
      return const ChatRunResult(
        text: 'Sesi masih memproses pesan sebelumnya.',
        success: false,
        retryable: true,
      );
    }
    try {
      final session = await sessions.getOrCreate(
        sessionId,
        channel: channel,
        userKey: userKey,
      );
      // Content-plane guard: block injection attempts and sanitize the rest.
      final now = DateTime.now().toUtc();
      final guardVerdict = promptGuard.inspectInput(
        text,
        provenance: Provenance.user,
      );
      if (guardVerdict.blocked) {
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
      final loop = AgentLoop(
        router: _router,
        contextBuilder: RuntimeContext(
          registry,
          memory: memory,
          sessions: sessions,
          skillRegistry: skills,
          expander: ContextExpander(workspaceRoot: workspace),
          toolFilter: toolFilter,
          personaPrompt: personaPrompt,
          reflectionEngine: reflectionEngine,
          ragPipeline: ragPipeline,
          layeredMemory: layeredMemory,
          toolSubsetThreshold: config.toolSubsetThreshold,
          toolSubsetK: config.toolSubsetK,
        ),
        compactor: Compactor(),
        // P0-3: the gate never prompts directly. It returns needsConfirm and
        // the loop's broker-backed confirm below becomes the single path, so
        // every surface settles the same durable apr_* request ID.
        gate: _TirithPreGate(gateOverride ?? buildGate(), tirith, channel),
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
        synthLlm: _router.providers.isEmpty ? null : _router.providers.values.first,
        shouldStop: () => safety.stopRequested,
        config: configOverride ?? defaultConfig,
        // P1-4: sanitize each delta before it reaches a live chat message;
        // the final reply is additionally guarded below as usual.
        onTextDelta:
            onTextDelta == null ? null : (d) => onTextDelta(_sanitizer.output(d)),
        audit: (call, verdict, result) {
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
      await loop.handle(
        InboundMessage(
          channel: channel,
          userKey: userKey,
          sessionKey: sessionId,
          text: effectiveText,
        ),
        session,
        cancelToken: cancelToken,
      );
      final answer = replies.join('\n');
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
      _lock.release(sessionId);
    }
  }

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
    } catch (_) {}
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
      onJob: (message, job) async {
        events.emit('job.started', {
          'job_id': job.id,
          'channel': job.channel,
          'session_id': message.sessionKey,
          'scheduled_at': job.scheduledAt?.toIso8601String(),
        });
        try {
          final outcome = await chatWithStatus(
            message.text,
            sessionId: message.sessionKey,
            channel: job.channel,
            userKey: job.userKey,
          );
          if (!outcome.success) {
            throw StateError(
              'scheduled agent turn did not complete successfully: ${outcome.text}',
            );
          }
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
          events.emit('job.failed', {
            'job_id': job.id,
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
      onDeliveryFailed: (job, runId, attempts, error) =>
          events.emit('job.delivery_failed', {
        'job_id': job.id,
        'channel': job.channel,
        'run_id': runId,
        'attempts': attempts,
        'error': _sanitizer.output('$error'),
        'session_id': '${job.channel}:${job.userKey}:job:${job.id}',
      }),
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
    } catch (_) {}
    try {
      await layeredMemory.save(p.join(dataDir, 'layered_memory.json'));
    } catch (_) {}
    try {
      await ragPipeline.lexical.save();
    } catch (_) {}
    try {
      await reflectionEngine?.save();
    } catch (_) {}
    try {
      await plugins.disposeAll();
    } catch (_) {}
    try {
      // Feedback/metric sink writes are tracked, not fire-and-forget, so the
      // last 👍/👎 and use events survive a graceful shutdown.
      await skills.flushPendingSinks();
    } catch (_) {}
    try {
      cancellations.cancelAll();
    } catch (_) {}
    try {
      await spans.close();
    } catch (_) {}
    try {
      await approvals.close();
    } catch (_) {}
    try {
      await scheduler?.shutdown();
    } catch (_) {}
    try {
      await mcpLoader.closeAll();
    } catch (_) {}
    try {
      await scriptRunner.close();
    } catch (_) {}
    try {
      await _sandbox?.dispose();
    } catch (_) {}
    try {
      if (_baseMemory is SafeMemoryStore) {
        final inner = (_baseMemory as SafeMemoryStore).inner;
        if (inner is SqliteMemoryStore) inner.close();
      } else if (_baseMemory is SqliteMemoryStore) {
        (_baseMemory as SqliteMemoryStore).close();
      }
    } catch (_) {}
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
