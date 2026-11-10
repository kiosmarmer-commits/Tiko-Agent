import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:agent_security/agent_security.dart';
import 'package:agent_scheduler/agent_scheduler.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:agent_tools/src/subagent.dart';
import 'package:path/path.dart' as p;

import 'provider_factory.dart';
import 'runtime_lock.dart';
import 'tiko_config.dart';
import 'capability.dart';
import 'event_bus.dart';
import 'approval_ledger.dart';
import 'resource_monitor.dart';
import 'offline_queue.dart';

const tikoVersion = '0.2.0';

enum CheckStatus { ok, warn, fail }

/// Result of one agent turn. Callers that schedule or queue work must inspect
/// [success] and retry failures instead of acknowledging any returned string.
class ChatRunResult {
  const ChatRunResult({required this.text, required this.success, this.retryable = false});
  final String text;
  final bool success;
  final bool retryable;
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
  });

  final TikoConfig config;
  final List<ConfigIssue> issues;
  final Map<String, LlmProvider> providers;
  final ToolRegistry registry;
  final SessionStore sessions;
  final MemoryStore memory;
  final String memoryBackend;
  final SafetyState safety;
  final SandboxKind sandboxKind;
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
  Scheduler? _scheduler;
  bool _closed = false;
  bool _mcpStarted = false;
  String resourceProfile = 'standard';

  final TaintTracker _taint = TaintTracker();
  final SessionLock _lock = SessionLock();
  final SecuritySanitizer _sanitizer = SecuritySanitizer();
  final CapabilityVault capabilities = CapabilityVault();
  final EventBus events = EventBus();
  late final ApprovalBroker approvals;
  late final SkillApprovalLedger skillLedger;
  late final SkillMetricsLedger skillMetrics;
  late final OfflineQueue offlineQueue;
  ResourceSnapshot? lastResources;




  /// Relative paths in the config are resolved against [baseDir] (the config
  /// file's directory) so every surface resolves the same locations.
  static Future<TikoRuntime> create({
    String configPath = 'config/agent.yaml',
    bool safe = true,
    bool allowInvalidConfig = false,
    Map<String, String>? env,
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

    final vectorIndex = BruteForceVectorIndex();
    MemoryStore memory;
    String backend;
    final sqlite = await SqliteMemoryStore.tryOpen(
      abs(cfg.dbPath),
      vectorIndex: vectorIndex,
      embedder: embedder,
    );
    if (sqlite != null) {
      memory = SafeMemoryStore(sqlite);
      backend = 'sqlite-fts5';
    } else {
      memory = SafeMemoryStore(PersistentMemoryStore(dataDir: dataDir, vectorIndex: vectorIndex));
      backend = 'json-fallback (degraded: libsqlite3 tidak tersedia)';
    }

    final sandboxKind = await SandboxRunner.detect();
    final sandbox = SandboxRunner(kind: sandboxKind, workspacePath: workspace);

    final skills = SkillRegistry();
    await skills.loadFromDirectory(abs('skills'));

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

    final registry = ToolRegistry()
      ..registerAll(createBuiltinTools(
        workspaceRoot: workspace,
        searxngBaseUrl: cfg.searxngBaseUrl,
        tavilyApiKey: TikoConfig.resolveSecretRef(cfg.tavilyApiKeyRef, env: env),
        sandbox: sandbox,
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
      ..register(ListUndoTool(ledger: undoLedger));

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

    final rt = TikoRuntime._(
      config: cfg,
      issues: issues,
      providers: providers,
      registry: registry,
      sessions: FileSessionStore(path: p.join(dataDir, 'sessions.json')),
      memory: memory,
      memoryBackend: backend,
      safety: safety,
      sandboxKind: sandboxKind,
      audit: AuditLog(directory: abs(cfg.logsDir)),
      workspace: workspace,
      dataDir: dataDir,
      skills: skills,
      skillsRoot: abs('skills'),
      goldenDir: abs('test/golden'),
      jobs: jobs,
      mcpLoader: mcpLoader,
      scriptRunner: scriptRunner,
      evidence: evidence,
      mcpEnvironment: env ?? Platform.environment,
      decision: decision,
    );
    rt.approvals = ApprovalBroker(p.join(dataDir, 'approvals.json'));
    await rt.approvals.load();
    rt.skillLedger = SkillApprovalLedger(p.join(dataDir, 'skill_approvals.json'));
    await rt.skillLedger.load();
    // Status frontmatter YAML bukan record approval dan memang di-reset oleh
    // loadFromDirectory; hanya ledger durabel yang boleh memulihkan status
    // approved/trial/retired, dan hanya saat fingerprint konten masih cocok.
    rt.skillLedger.applyTo(skills);
    // Metrik penggunaan skill (uses/successes) juga durabel: ledger
    // memulihkan angka setelah restart dan sink registry mencatat setiap
    // pemakaian/feedback secara fire-and-forget (kegagalan tulis tidak
    // boleh menggagalkan giliran agent).
    rt.skillMetrics = SkillMetricsLedger(p.join(dataDir, 'skill_metrics.json'));
    await rt.skillMetrics.load();
    rt.skillMetrics.applyTo(skills);
    skills.onUseRecorded = rt.skillMetrics.recordUse;
    skills.onFeedbackRecorded = rt.skillMetrics.recordFeedback;
    rt.offlineQueue = OfflineQueue(p.join(dataDir, 'offline'));
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
    // NEW-12: forged tools are contract-tested before installation;
    // fail-closed when no OS sandbox can execute the tests.
    if (rt.registry.get('tool_forge') == null) {
      rt.registry.register(ToolForgeTool(
        forge: ToolForge(sandbox: sandbox),
        hasTool: (name) => rt.registry.get(name) != null,
        registerTool: rt.registry.register,
      ));
    }
    final snap = ResourceMonitor.capture(dataDir: dataDir);
    rt.lastResources = snap;
    rt.resourceProfile = snap.profile;
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
    return SafetyPermissionGate(withCap, safety);
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
            contextBuilder: _RuntimeContext(
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

  /// Admin view of memory facts. Unwraps the safety decorator so both
  /// SQLite and JSON fallback backends expose the same interface.
  Future<List<Map<String, dynamic>>> listMemories({int limit = 200}) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..1000');
    }
    final store = memory is SafeMemoryStore
        ? (memory as SafeMemoryStore).inner
        : memory;
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
  Future<bool> deleteMemory(String id) async {
    if (id.isEmpty || id.length > 128 || id.contains('\u0000')) return false;
    final store = memory is SafeMemoryStore
        ? (memory as SafeMemoryStore).inner
        : memory;
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
    Future<bool> Function(ToolCall call, Session session)? confirm,
  }) async => (await chatWithStatus(
        text,
        sessionId: sessionId,
        channel: channel,
        userKey: userKey,
        confirm: confirm,
      )).text;

  /// One agent turn with explicit completion status for durable queues/jobs.
  Future<ChatRunResult> chatWithStatus(
    String text, {
    String sessionId = 'cli:default',
    String channel = 'cli',
    String userKey = 'local',
    Future<bool> Function(ToolCall call, Session session)? confirm,
    PermissionGate? gateOverride,
    AgentConfig? configOverride,
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
      final replies = <String>[];
      final defaultConfig = AgentConfig(
          maxIterations: resourceProfile == 'eco' ? 6 : config.maxIterations,
          maxTokensPerTask: resourceProfile == 'eco' ? 20000 : config.maxTokensPerTask,
          maxWallClockSec: resourceProfile == 'eco' ? 120 : config.maxWallClockSec,
          maxToolCalls: resourceProfile == 'eco' ? 12 : config.maxToolCalls,
        );
      final loop = AgentLoop(
        router: _router,
        contextBuilder: _RuntimeContext(
          registry,
          memory: memory,
          sessions: sessions,
          skillRegistry: skills,
          expander: ContextExpander(workspaceRoot: workspace),
        ),
        compactor: Compactor(),
        gate: gateOverride ?? buildGate(confirm: confirm),
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
        audit: (call, verdict, result) {
          evidence.recordCall(result.callId, call.name, result.content);
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
            unawaited(() async {
              try {
                final userDecision = await confirm(call, sess);
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
      await loop.handle(
        InboundMessage(
          channel: channel,
          userKey: userKey,
          sessionKey: sessionId,
          text: text,
        ),
        session,
      );
      return ChatRunResult(
        text: replies.join('\n'),
        success: loop.lastTurnSucceeded,
        retryable: !loop.lastTurnSucceeded,
      );
    } finally {
      _lock.release(sessionId);
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
        : _AllowlistToolGate(allowedTools);
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
    double cost = 0.0;

    try {
      final outcome = await chatWithStatus(
        prompt,
        sessionId: subagentId,
        channel: parent.channel,
        userKey: parent.userKey,
        gateOverride: isolationGate,
        configOverride: subConfig,
      );
      
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      final timeSeconds = duration.inMilliseconds / 1000.0;
      
      // For now, estimate token count based on output length
      // In production, this would come from the LLM response
      tokenCount = outcome.text.length ~/ 4; // Rough estimate
      
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
      if (memory is SafeMemoryStore) {
        final inner = (memory as SafeMemoryStore).inner;
        if (inner is SqliteMemoryStore) inner.close();
      } else if (memory is SqliteMemoryStore) {
        (memory as SqliteMemoryStore).close();
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

  /// PRD §6 `tiko doctor`: environment diagnosis with actionable details.
  Future<List<DoctorCheck>> doctor({
    bool probe = false,
    int? apiPort,
    LockInfo? lock,
  }) async {
    final out = <DoctorCheck>[];

    // Configuration is one diagnostic category, not a guard around the host
    // checks. A broken config must never hide the information needed to fix it.
    if (issues.isEmpty) {
      out.add(const DoctorCheck('config', CheckStatus.ok, 'valid'));
    } else {
      for (final issue in issues) {
        out.add(DoctorCheck(
          'config ${issue.path}',
          issue.fatal ? CheckStatus.fail : CheckStatus.warn,
          issue.message,
        ));
      }
    }

    final resources = ResourceMonitor.capture(dataDir: dataDir);
    lastResources = resources;
    resourceProfile = resources.profile;
    out.add(DoctorCheck(
      'resource_profile',
      resources.profile == 'eco' ? CheckStatus.warn : CheckStatus.ok,
      resources.profile,
    ));
    out.add(DoctorCheck(
      'ram',
      resources.memAvailableMb == null
          ? CheckStatus.warn
          : resources.memAvailableMb! < ResourceMonitor.criticalRamMb
              ? CheckStatus.fail
              : resources.memAvailableMb! < ResourceMonitor.ecoRamMb
                  ? CheckStatus.warn
                  : CheckStatus.ok,
      resources.memAvailableMb == null
          ? 'unknown (host tidak menyediakan /proc/meminfo)'
          : '${resources.memAvailableMb} MB available / '
              '${resources.memTotalMb ?? "?"} MB total',
    ));
    out.add(DoctorCheck(
      'disk',
      resources.diskFreeMb == null
          ? CheckStatus.warn
          : resources.diskFreeMb! < ResourceMonitor.criticalDiskMb
              ? CheckStatus.fail
              : CheckStatus.ok,
      resources.diskFreeMb == null
          ? 'unknown (df tidak tersedia atau path tidak dapat dibaca)'
          : '${resources.diskFreeMb} MB free',
    ));
    out.add(DoctorCheck(
      'termux',
      CheckStatus.ok,
      resources.isTermux ? 'detected' : 'not termux',
    ));
    out.add(DoctorCheck(
      'sqlite_native',
      resources.hasSqliteNative ? CheckStatus.ok : CheckStatus.warn,
      resources.hasSqliteNative ? 'native library found' : 'missing — JSON memory fallback',
    ));
    out.add(DoctorCheck(
      'network',
      resources.networkLikely ? CheckStatus.ok : CheckStatus.warn,
      resources.networkLikely
          ? 'default route detected'
          : 'no default route — offline queue available',
    ));
    try {
      final count = await offlineQueue.length();
      out.add(DoctorCheck(
        'offline_queue',
        count == 0 ? CheckStatus.ok : CheckStatus.warn,
        count == 0 ? 'empty' : '$count pending item(s)',
      ));
    } catch (error) {
      out.add(DoctorCheck('offline_queue', CheckStatus.warn, 'unavailable: $error'));
    }

    out.add(
      Directory(workspace).existsSync()
          ? DoctorCheck('workspace', CheckStatus.ok, workspace)
          : DoctorCheck('workspace', CheckStatus.fail, 'tidak ada: $workspace'),
    );
    try {
      final probeFile = File(p.join(dataDir, '.doctor_write_test'));
      await probeFile.writeAsString('ok', flush: true);
      await probeFile.delete();
      out.add(DoctorCheck('data_dir', CheckStatus.ok, dataDir));
    } catch (error) {
      out.add(DoctorCheck('data_dir', CheckStatus.fail, 'tidak bisa menulis: $error'));
    }

    if (jobs.loadError != null) {
      out.add(DoctorCheck('scheduler_store', CheckStatus.fail, jobs.loadError!));
    } else {
      out.add(DoctorCheck('scheduler_store', CheckStatus.ok, '${jobs.all.length} job(s) loaded'));
    }
    final mcpStatus = mcpLoader.statuses;
    out.add(DoctorCheck(
      'mcp',
      mcpStatus.any((status) => status['status'] != 'ready')
          ? CheckStatus.warn
          : CheckStatus.ok,
      mcpStatus.isEmpty ? 'no MCP servers configured' : mcpStatus.toString(),
    ));

    out.add(DoctorCheck(
      'memory',
      memoryBackend.startsWith('sqlite') ? CheckStatus.ok : CheckStatus.warn,
      memoryBackend,
    ));
    out.add(DoctorCheck(
      'sandbox',
      sandboxKind == SandboxKind.none ? CheckStatus.warn : CheckStatus.ok,
      sandboxKind == SandboxKind.none
          ? 'tidak ada sandbox OS; shell, script, dan MCP dinonaktifkan'
          : sandboxKind.name,
    ));

    if (lock != null) {
      out.add(DoctorCheck(
        'daemon',
        CheckStatus.ok,
        'pid ${lock.pid} port ${lock.port ?? '-'} '
            'sejak ${lock.startedAt.toIso8601String()}',
      ));
    }
    if (apiPort != null) {
      final free = await _portFree(apiPort);
      out.add(DoctorCheck(
        'port $apiPort',
        free || lock?.port == apiPort ? CheckStatus.ok : CheckStatus.warn,
        free
            ? 'bebas'
            : lock?.port == apiPort
                ? 'dipakai instance Tiko sendiri'
                : 'dipakai proses lain; ubah api.port atau hentikan prosesnya',
      ));
    }

    if (config.providers.isEmpty) {
      out.add(const DoctorCheck(
        'provider',
        CheckStatus.fail,
        'tidak ada provider yang terkonfigurasi',
      ));
    } else {
      for (final provider in config.providers.values) {
        if (!provider.enabled) {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            provider.id == config.defaultProvider
                ? CheckStatus.fail
                : CheckStatus.warn,
            'disabled',
          ));
        } else if (!probe && provider.type != 'mock') {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            CheckStatus.warn,
            '${provider.type} belum diprobe; gunakan --probe',
          ));
        } else if (provider.type == 'mock') {
          out.add(DoctorCheck(
            'provider ${provider.id}',
            CheckStatus.ok,
            'mock ready',
          ));
        } else {
          out.add(await _probeProvider(provider));
        }
      }
    }
    return out;
  }

  Future<DoctorCheck> _probeProvider(ProviderConfig c) async {
    final base = (c.baseUrl ?? 'http://127.0.0.1:11434').replaceAll(RegExp(r'/+$'), '');
    final url = c.type == 'ollama_native' ? '$base/api/tags' : '$base/models';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      final status = res.statusCode >= 200 && res.statusCode < 400
          ? CheckStatus.ok
          : res.statusCode == 401 || res.statusCode == 403 || res.statusCode == 404
              ? CheckStatus.warn
              : CheckStatus.fail;
      final detail = switch (res.statusCode) {
        401 || 403 => 'HTTP ${res.statusCode}: host aktif tetapi autentikasi ditolak ($url)',
        404 => 'HTTP 404: endpoint tidak ditemukan ($url)',
        _ => 'HTTP ${res.statusCode} dari $url',
      };
      return DoctorCheck('provider ${c.id}', status, detail);
    } catch (e) {
      return DoctorCheck('provider ${c.id}', CheckStatus.fail, 'tidak terjangkau: $url ($e)');
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

}

/// Injects the registry's tool specs and persistent history into each turn.
class _RuntimeContext extends ContextBuilder {
  _RuntimeContext(
    this.registry, {
    required super.memory,
    super.sessions,
    super.skillRegistry,
    super.expander,
  });
  final ToolRegistry registry;

  @override
  Future<AgentContext> build(
    Session session,
    InboundMessage m,
    RouteDecision route,
  ) async {
    final ctx = await super.build(session, m, route);
    return AgentContext(
      messages: ctx.messages,
      tools: route.needTools ? registry.specs : const <ToolSpec>[],
      session: ctx.session,
      systemPrompt: ctx.systemPrompt,
    );
  }
}


/// Permission gate fail-closed untuk evaluator golden terisolasi: tool
/// hanya diizinkan bila dideklarasikan oleh tugas golden atau skill yang
/// sedang diuji. Selebihnya ditolak tanpa konfirmasi.
class _EvalToolGate implements PermissionGate {
  const _EvalToolGate(this.allowedTools);

  final Set<String> allowedTools;

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    if (allowedTools.contains(call.name)) {
      return const PermissionResult(PermissionVerdict.allowed);
    }
    return const PermissionResult(
      PermissionVerdict.denied,
      reason: 'tool di luar allowlist tugas golden',
    );
  }
}

/// Batas byte operasi (maxBytes) dihitung dari payload aktual yang
/// ditulis, bukan dari panjang fingerprint, sehingga konten tulis/patch
/// tidak bisa melebihi ukuran yang disetujui walau fingerprintnya pendek.
bool _withinApprovedBytes(ToolCall call, int maxBytes) {
  for (final key in const ['content', 'new', 'body']) {
    final value = call.args[key];
    if (value is String && utf8.encode(value).length > maxBytes) {
      return false;
    }
  }
  return true;
}

void stdoutWrite(String m) {
  try {
    stdout.writeln(m);
  } catch (_) {}
}
