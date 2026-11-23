/// DTO typed untuk domain GUI (GUI-P0-03). Semua factory toleran terhadap
/// field yang hilang agar daemon versi lama tetap bisa dirender.
class SessionSummary {
  const SessionSummary({
    required this.id,
    this.title = '',
    this.channel = '',
    this.updatedAt = '',
    this.turns = 0,
  });

  final String id;
  final String title;
  final String channel;
  final String updatedAt;
  final int turns;

  factory SessionSummary.fromMap(Map<String, dynamic> map) => SessionSummary(
        id: '${map['id'] ?? ''}',
        title: '${map['title'] ?? ''}',
        channel: '${map['channel'] ?? ''}',
        updatedAt: '${map['updated_at'] ?? ''}',
        turns: map['turns'] is num ? (map['turns'] as num).toInt() : 0,
      );

  String get displayTitle => title.isEmpty ? id : title;
}

class SessionMessage {
  const SessionMessage({
    required this.role,
    required this.content,
    this.at = '',
  });

  final String role;
  final String content;
  final String at;

  factory SessionMessage.fromMap(Map<String, dynamic> map) => SessionMessage(
        role: '${map['role'] ?? 'user'}',
        content: '${map['content'] ?? ''}',
        at: '${map['at'] ?? map['ts'] ?? ''}',
      );
}

class ApprovalSummary {
  const ApprovalSummary({
    required this.id,
    this.tool = '',
    this.risk = '',
    this.args = '',
    this.state = '',
    this.actor = '',
    this.createdAt = '',
  });

  final String id;
  final String tool;
  final String risk;
  final String args;
  final String state;
  final String actor;
  final String createdAt;

  bool get isPending => state == 'pending';

  factory ApprovalSummary.fromMap(Map<String, dynamic> map) => ApprovalSummary(
        id: '${map['id'] ?? ''}',
        tool: '${map['tool'] ?? ''}',
        risk: '${map['risk'] ?? ''}',
        args: '${map['args'] ?? ''}',
        state: '${map['state'] ?? ''}',
        actor: '${map['actor'] ?? ''}',
        createdAt: '${map['created_at'] ?? ''}',
      );
}

class MemoryFact {
  const MemoryFact({
    required this.id,
    this.text = '',
    this.kind = '',
  });

  final String id;
  final String text;
  final String kind;

  factory MemoryFact.fromMap(Map<String, dynamic> map) => MemoryFact(
        id: '${map['id'] ?? ''}',
        text: '${map['text'] ?? ''}',
        kind: '${map['kind'] ?? ''}',
      );
}

class RuntimeEvent {
  const RuntimeEvent({
    required this.type,
    this.at = '',
  });

  final String type;
  final String at;

  factory RuntimeEvent.fromMap(Map<String, dynamic> map) => RuntimeEvent(
        type: '${map['type'] ?? ''}',
        at: '${map['at'] ?? ''}',
      );
}

/// Task kanban (GUI-P1-01): read-only, sumber data identik dengan web UI.
class TaskItem {
  const TaskItem({
    required this.id,
    this.title = '',
    this.state = 'backlog',
    this.claimedBy = '',
    this.result = '',
  });

  final String id;
  final String title;
  final String state;
  final String claimedBy;
  final String result;

  factory TaskItem.fromMap(Map<String, dynamic> map) => TaskItem(
        id: '${map['id'] ?? ''}',
        title: '${map['title'] ?? ''}',
        state: '${map['state'] ?? 'backlog'}',
        claimedBy: '${map['claimed_by'] ?? ''}',
        result: '${map['result'] ?? ''}',
      );
}

/// Satu file log daemon (GUI-P1-02).
class LogFileInfo {
  const LogFileInfo({
    required this.name,
    this.bytes = 0,
  });

  final String name;
  final int bytes;

  factory LogFileInfo.fromMap(Map<String, dynamic> map) => LogFileInfo(
        name: '${map['name'] ?? ''}',
        bytes: map['bytes'] is num ? (map['bytes'] as num).toInt() : 0,
      );
}

/// Isi satu file log (GUI-P1-02).
class LogFileContent {
  const LogFileContent({
    required this.name,
    this.bytes = 0,
    this.truncated = false,
    this.content = '',
  });

  final String name;
  final int bytes;
  final bool truncated;
  final String content;

  factory LogFileContent.fromMap(Map<String, dynamic> map) => LogFileContent(
        name: '${map['name'] ?? ''}',
        bytes: map['bytes'] is num ? (map['bytes'] as num).toInt() : 0,
        truncated: map['truncated'] == true,
        content: '${map['content'] ?? ''}',
      );
}

/// Satu skill pada Skills Manager (GUI-P1-03). Status mengikuti lifecycle
/// backend (draft/trial/approved/retired); metrics berasal dari ledger.
class SkillItem {
  const SkillItem({
    required this.slug,
    this.name = '',
    this.description = '',
    this.triggers = const [],
    this.tools = const [],
    this.version = 1,
    this.status = 'draft',
    this.uses = 0,
    this.successes = 0,
    this.positive = 0,
    this.negative = 0,
    this.goldenScore = 0,
    this.goldenTotal = 0,
    this.approvedBy,
  });

  final String slug;
  final String name;
  final String description;
  final List<String> triggers;
  final List<String> tools;
  final int version;
  final String status;
  final int uses;
  final int successes;
  final int positive;
  final int negative;
  final double goldenScore;
  final double goldenTotal;
  final String? approvedBy;

  /// Feedback hanya berlaku untuk skill aktif (trial/approved) sesuai
  /// gate backend RuntimeSkillApi.recordFeedback.
  bool get feedbackAllowed => status != 'draft' && status != 'retired';

  double get successRate => uses == 0 ? 0 : successes / uses;

  factory SkillItem.fromMap(Map<String, dynamic> map) {
    final metrics =
        Map<String, dynamic>.from(map['metrics'] as Map? ?? const {});
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return SkillItem(
      slug: '${map['slug'] ?? ''}',
      name: '${map['name'] ?? ''}',
      description: '${map['description'] ?? ''}',
      triggers: [
        for (final t in map['triggers'] as List? ?? const []) '$t',
      ],
      tools: [
        for (final t in map['tools'] as List? ?? const []) '$t',
      ],
      version: asInt(map['version']),
      status: '${map['status'] ?? 'draft'}',
      uses: asInt(map['uses']),
      successes: asInt(map['successes']),
      positive: asInt(metrics['positive']),
      negative: asInt(metrics['negative']),
      goldenScore:
          map['golden_score'] is num ? (map['golden_score'] as num).toDouble() : 0,
      goldenTotal:
          map['golden_total'] is num ? (map['golden_total'] as num).toDouble() : 0,
      approvedBy:
          map['approved_by'] == null ? null : '${map['approved_by']}',
    );
  }
}

/// Hasil gate skill (GUI-P1-03 evaluate/approve/rollback): SkillGateResult
/// dari SkillPromotionGate di agent_core.
class SkillGateOutcome {
  const SkillGateOutcome({
    required this.ok,
    required this.slug,
    this.stage = '',
    this.findings = const [],
    this.goldenScore = 0,
    this.goldenTotal = 0,
    this.message = '',
  });

  final bool ok;
  final String slug;
  final String stage;
  final List<String> findings;
  final double goldenScore;
  final double goldenTotal;
  final String message;

  factory SkillGateOutcome.fromMap(Map<String, dynamic> map) =>
      SkillGateOutcome(
        ok: map['ok'] == true,
        slug: '${map['slug'] ?? ''}',
        stage: '${map['stage'] ?? ''}',
        findings: [
          for (final f in map['findings'] as List? ?? const []) '$f',
        ],
        goldenScore:
            map['golden_score'] is num ? (map['golden_score'] as num).toDouble() : 0,
        goldenTotal:
            map['golden_total'] is num ? (map['golden_total'] as num).toDouble() : 0,
        message: '${map['message'] ?? ''}',
      );
}

/// Satu baris riwayat skill (GUI-P1-03): SkillLedgerRecord dari ledger.
class SkillHistoryEntry {
  const SkillHistoryEntry({
    required this.action,
    required this.actor,
    required this.at,
    this.reason,
  });

  final String action;
  final String actor;
  final String at;
  final String? reason;

  factory SkillHistoryEntry.fromMap(Map<String, dynamic> map) =>
      SkillHistoryEntry(
        action: '${map['action'] ?? ''}',
        actor: '${map['actor'] ?? ''}',
        at: '${map['at'] ?? ''}',
        reason: map['reason'] == null ? null : '${map['reason']}',
      );
}

/// Snapshot provider & model manager (GUI-P1-05): mirror payload
/// `GET /v1/providers` — daftar provider + health circuit breaker, mapping
/// tier, dan override `/model` per sesi.
class ProvidersSnapshot {
  const ProvidersSnapshot({
    this.defaultId,
    this.providers = const [],
    this.tiers = const {},
    this.sessionOverrides = const {},
    this.sessionModelChoices = const {},
  });

  final String? defaultId;
  final List<ProviderItem> providers;
  final Map<String, String> tiers;
  final Map<String, String> sessionOverrides;

  /// Model eksplisit hasil discovery per sesi (Hermes-parity); kosong bila
  /// sesi memakai model default provider.
  final Map<String, String> sessionModelChoices;

  factory ProvidersSnapshot.fromMap(Map<String, dynamic> map) {
    final tiers = Map<String, dynamic>.from(map['tiers'] as Map? ?? const {});
    final overrides = Map<String, dynamic>.from(
        map['session_overrides'] as Map? ?? const {});
    final choices = Map<String, dynamic>.from(
        map['session_model_choices'] as Map? ?? const {});
    return ProvidersSnapshot(
      defaultId: map['default'] == null ? null : '${map['default']}',
      providers: [
        for (final p in map['providers'] as List? ?? const [])
          ProviderItem.fromMap(Map<String, dynamic>.from(p as Map)),
      ],
      tiers: {for (final e in tiers.entries) e.key: '${e.value}'},
      sessionOverrides: {for (final e in overrides.entries) e.key: '${e.value}'},
      sessionModelChoices: {
        for (final e in choices.entries) e.key: '${e.value}',
      },
    );
  }
}

/// Satu provider chat + health breaker-nya.
class ProviderItem {
  const ProviderItem({
    required this.id,
    this.toolCalling = false,
    this.vision = false,
    this.streaming = true,
    this.maxContext = 0,
    this.health,
  });

  final String id;
  final bool toolCalling;
  final bool vision;
  final bool streaming;
  final int maxContext;
  final ProviderHealthInfo? health;

  factory ProviderItem.fromMap(Map<String, dynamic> map) {
    final caps = Map<String, dynamic>.from(
        map['capabilities'] as Map? ?? const {});
    return ProviderItem(
      id: '${map['id'] ?? ''}',
      toolCalling: caps['tool_calling'] == true,
      vision: caps['vision'] == true,
      streaming: caps['streaming'] != false,
      maxContext: caps['max_context'] is num
          ? (caps['max_context'] as num).toInt()
          : 0,
      health: map['health'] == null
          ? null
          : ProviderHealthInfo.fromMap(
              Map<String, dynamic>.from(map['health'] as Map)),
    );
  }
}

/// Health circuit breaker satu provider (ProviderHealth.toJson).
class ProviderHealthInfo {
  const ProviderHealthInfo({
    this.failures = 0,
    this.successes = 0,
    this.open = false,
    this.phase = 'unknown',
    this.lastError,
    this.lastLatencyMs = 0,
  });

  final int failures;
  final int successes;
  final bool open;
  final String phase;
  final String? lastError;
  final double lastLatencyMs;

  factory ProviderHealthInfo.fromMap(Map<String, dynamic> map) =>
      ProviderHealthInfo(
        failures: map['failures'] is num ? (map['failures'] as num).toInt() : 0,
        successes:
            map['successes'] is num ? (map['successes'] as num).toInt() : 0,
        open: map['open'] == true,
        phase: '${map['phase'] ?? 'unknown'}',
        lastError: map['last_error'] == null ? null : '${map['last_error']}',
        lastLatencyMs: map['last_latency_ms'] is num
            ? (map['last_latency_ms'] as num).toDouble()
            : 0,
      );
}

/// Profil bot persisten (GUI-P1-04): mirror BotProfile.toJson dari
/// tiko_runtime (snake_case).
class BotProfileItem {
  const BotProfileItem({
    required this.id,
    this.name = '',
    this.persona = '',
    this.model,
    this.greeting = '',
    this.toolAllowlist = const [],
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String name;
  final String persona;
  final String? model;
  final String greeting;
  final List<String> toolAllowlist;
  final String createdAt;
  final String updatedAt;

  factory BotProfileItem.fromMap(Map<String, dynamic> map) => BotProfileItem(
        id: '${map['id'] ?? ''}',
        name: '${map['name'] ?? ''}',
        persona: '${map['persona'] ?? ''}',
        model: map['model'] == null ? null : '${map['model']}',
        greeting: '${map['greeting'] ?? ''}',
        toolAllowlist: [
          for (final t in map['tool_allowlist'] as List? ?? const []) '$t',
        ],
        createdAt: '${map['created_at'] ?? ''}',
        updatedAt: '${map['updated_at'] ?? ''}',
      );
}

/// Snapshot plugin & tools manager (GUI-P1-06): mirror payload
/// `GET /v1/plugins` — daftar plugin + status consent, katalog tool
/// registry host, dan status server MCP.
class PluginsToolsSnapshot {
  const PluginsToolsSnapshot({
    this.plugins = const [],
    this.tools = const [],
    this.events = const [],
    this.mcp,
  });

  final List<PluginItem> plugins;
  final List<ToolInfo> tools;
  final List<PluginEventInfo> events;
  final McpStatusInfo? mcp;

  factory PluginsToolsSnapshot.fromMap(Map<String, dynamic> map) {
    final mcp = map['mcp'] as Map?;
    return PluginsToolsSnapshot(
      plugins: [
        for (final p in map['plugins'] as List? ?? const [])
          PluginItem.fromMap(Map<String, dynamic>.from(p as Map)),
      ],
      tools: [
        for (final t in map['tools'] as List? ?? const [])
          ToolInfo.fromMap(Map<String, dynamic>.from(t as Map)),
      ],
      events: [
        for (final e in map['events'] as List? ?? const [])
          PluginEventInfo.fromMap(Map<String, dynamic>.from(e as Map)),
      ],
      mcp: mcp == null
          ? null
          : McpStatusInfo.fromMap(Map<String, dynamic>.from(mcp)),
    );
  }
}

/// Satu plugin: status registrasi + consent (GUI-P1-06).
class PluginItem {
  const PluginItem({
    required this.id,
    this.registered = false,
    this.pending = false,
    this.granted = const [],
    this.requested = const [],
  });

  final String id;
  final bool registered;
  final bool pending;

  /// Permission yang sudah disetujui administrator.
  final List<String> granted;

  /// Permission yang diminta plugin pending consent.
  final List<String> requested;

  factory PluginItem.fromMap(Map<String, dynamic> map) => PluginItem(
        id: '${map['id'] ?? ''}',
        registered: map['registered'] == true,
        pending: map['pending'] == true,
        granted: [
          for (final p in map['granted'] as List? ?? const []) '$p',
        ],
        requested: [
          for (final p in map['requested'] as List? ?? const []) '$p',
        ],
      );
}

/// Satu tool terdaftar di registry host (GUI-P1-06, read-only).
class ToolInfo {
  const ToolInfo({
    required this.name,
    this.description = '',
    this.risk = 'low',
    this.timeoutSec = 30,
    this.parallelSafe = false,
  });

  final String name;
  final String description;
  final String risk;
  final int timeoutSec;
  final bool parallelSafe;

  factory ToolInfo.fromMap(Map<String, dynamic> map) => ToolInfo(
        name: '${map['name'] ?? ''}',
        description: '${map['description'] ?? ''}',
        risk: '${map['risk'] ?? 'low'}',
        timeoutSec: map['timeout_sec'] is num
            ? (map['timeout_sec'] as num).toInt()
            : 30,
        parallelSafe: map['parallel_safe'] == true,
      );
}

/// Event hook plugin terakhir (GUI-P1-06, maksimal 10 entri).
class PluginEventInfo {
  const PluginEventInfo({
    this.plugin = '',
    this.hook = '',
    this.detail,
    this.error,
    this.at = '',
  });

  final String plugin;
  final String hook;
  final String? detail;
  final String? error;
  final String at;

  factory PluginEventInfo.fromMap(Map<String, dynamic> map) =>
      PluginEventInfo(
        plugin: '${map['plugin'] ?? ''}',
        hook: '${map['hook'] ?? ''}',
        detail: map['detail'] == null ? null : '${map['detail']}',
        error: map['error'] == null ? null : '${map['error']}',
        at: '${map['at'] ?? ''}',
      );
}

/// Status server MCP (GUI-P1-06, read-only): konfigurasi + hasil loader.
class McpStatusInfo {
  const McpStatusInfo({
    this.started = false,
    this.configured = const [],
    this.loader = const [],
  });

  final bool started;
  final List<McpServerInfo> configured;

  /// Map mentah per server dari `McpToolLoader.statuses` (ready/failed/
  /// disabled/invalid + detail + jumlah tool).
  final List<Map<String, dynamic>> loader;

  factory McpStatusInfo.fromMap(Map<String, dynamic> map) => McpStatusInfo(
        started: map['started'] == true,
        configured: [
          for (final s in map['configured'] as List? ?? const [])
            McpServerInfo.fromMap(Map<String, dynamic>.from(s as Map)),
        ],
        loader: [
          for (final s in map['loader'] as List? ?? const [])
            Map<String, dynamic>.from(s as Map),
        ],
      );
}

/// Konfigurasi satu server MCP (GUI-P1-06, config immutable).
class McpServerInfo {
  const McpServerInfo({
    required this.id,
    this.type = 'stdio',
    this.enabled = true,
    this.risk = 'high',
    this.command,
    this.allow = const [],
  });

  final String id;
  final String type;
  final bool enabled;
  final String risk;
  final String? command;
  final List<String> allow;

  factory McpServerInfo.fromMap(Map<String, dynamic> map) => McpServerInfo(
        id: '${map['id'] ?? ''}',
        type: '${map['type'] ?? 'stdio'}',
        enabled: map['enabled'] != false,
        risk: '${map['risk'] ?? 'high'}',
        command: map['command'] == null ? null : '${map['command']}',
        allow: [
          for (final a in map['allow'] as List? ?? const []) '$a',
        ],
      );
}

/// Snapshot channels setup (GUI-P1-07): mirror payload `GET /v1/channels`
/// — status channel gateway aktif + nama variabel env yang
/// mengonfigurasinya (read-only; ubah env lalu restart daemon).
class ChannelsSnapshot {
  const ChannelsSnapshot({this.channels = const []});

  final List<ChannelInfo> channels;

  factory ChannelsSnapshot.fromMap(Map<String, dynamic> map) =>
      ChannelsSnapshot(
        channels: [
          for (final c in map['channels'] as List? ?? const [])
            ChannelInfo.fromMap(Map<String, dynamic>.from(c as Map)),
        ],
      );
}

/// Satu channel gateway: status aktif + nama env (GUI-P1-07, read-only).
class ChannelInfo {
  const ChannelInfo({
    required this.channel,
    this.active = false,
    this.env = const [],
  });

  final String channel;
  final bool active;

  /// Hanya **nama** variabel env; nilai rahasia tidak pernah dikirim server.
  final List<String> env;

  factory ChannelInfo.fromMap(Map<String, dynamic> map) => ChannelInfo(
        channel: '${map['channel'] ?? ''}',
        active: map['active'] == true,
        env: [
          for (final e in map['env'] as List? ?? const []) '$e',
        ],
      );
}

/// Snapshot job automation (GUI-P1-09): mirror payload `GET /v1/jobs`
/// — daftar cron job scheduler yang durabel di `jobs.json`.
class JobsSnapshot {
  const JobsSnapshot({this.jobs = const []});

  final List<JobInfo> jobs;

  factory JobsSnapshot.fromMap(Map<String, dynamic> map) => JobsSnapshot(
        jobs: [
          for (final j in map['jobs'] as List? ?? const [])
            JobInfo.fromMap(Map<String, dynamic>.from(j as Map)),
        ],
      );
}

/// Satu cron job scheduler dengan status delivery (GUI-P1-09).
class JobInfo {
  const JobInfo({
    required this.id,
    required this.cron,
    required this.prompt,
    required this.channel,
    required this.userKey,
    required this.nextRun,
    this.lastRun,
    this.enabled = true,
    this.missedPolicy = 'runOnce',
    this.timezone = 'UTC',
    this.deliveryState = 'none',
  });

  final String id;
  final String cron;
  final String prompt;
  final String channel;
  final String userKey;
  final String nextRun;
  final String? lastRun;
  final bool enabled;
  final String missedPolicy;
  final String timezone;

  /// none | pending | delivered | failed — status delivery terakhir.
  final String deliveryState;

  factory JobInfo.fromMap(Map<String, dynamic> map) => JobInfo(
        id: '${map['id'] ?? ''}',
        cron: '${map['cron'] ?? ''}',
        prompt: '${map['prompt'] ?? ''}',
        channel: '${map['channel'] ?? ''}',
        userKey: '${map['user_key'] ?? ''}',
        nextRun: '${map['next_run'] ?? ''}',
        lastRun: map['last_run'] == null ? null : '${map['last_run']}',
        enabled: map['enabled'] != false,
        missedPolicy: '${map['missed_policy'] ?? 'runOnce'}',
        timezone: '${map['timezone'] ?? 'UTC'}',
        deliveryState: '${map['delivery_state'] ?? 'none'}',
      );
}

/// Snapshot Security Center (GUI-P1-10): mirror payload `GET /v1/security`
/// — konsolidasi status keamanan runtime read-only, tanpa nilai rahasia.
class SecuritySnapshot {
  const SecuritySnapshot({
    this.safeMode = false,
    this.panic = false,
    this.stopRequested = false,
    this.sandbox = 'unknown',
    this.sealedStorage = false,
    this.plugins = const [],
    this.tokenAnomalyEnabled = false,
    this.quarantinesToday = 0,
    this.maxQuarantinesPerDay = 0,
    this.tokenSkillStats = const [],
    this.rateWindowSec = 0,
    this.rateMaxEvents = 0,
    this.guardBlockedTurns = 0,
    this.guardSanitizedTurns = 0,
    this.auditTotal = 0,
    this.auditRecent = const [],
    this.activeSessions = 0,
  });

  final bool safeMode;
  final bool panic;
  final bool stopRequested;
  final String sandbox;

  /// True saat penyimpanan kredensial terenkripsi at-rest — sekadar flag,
  /// passphrase tidak pernah dikirim.
  final bool sealedStorage;
  final List<SecurityPluginItem> plugins;
  final bool tokenAnomalyEnabled;
  final int quarantinesToday;
  final int maxQuarantinesPerDay;
  final List<SkillTokenStat> tokenSkillStats;
  final int rateWindowSec;
  final int rateMaxEvents;
  final int guardBlockedTurns;
  final int guardSanitizedTurns;
  final int auditTotal;

  /// Entri audit terbaru (sudah direduksi server; tetap Map karena kolom
  /// per-entri heterogen).
  final List<Map<String, dynamic>> auditRecent;
  final int activeSessions;

  factory SecuritySnapshot.fromMap(Map<String, dynamic> map) {
    final safety = map['safety'] as Map? ?? const {};
    final credentials = map['credentials'] as Map? ?? const {};
    final tokenAnomaly = map['token_anomaly'] as Map? ?? const {};
    final rate = map['rate_anomaly'] as Map? ?? const {};
    final guard = map['guard'] as Map? ?? const {};
    final audit = map['audit'] as Map? ?? const {};
    return SecuritySnapshot(
      safeMode: safety['safe_mode'] == true,
      panic: safety['panic'] == true,
      stopRequested: safety['stop_requested'] == true,
      sandbox: '${map['sandbox'] ?? 'unknown'}',
      sealedStorage: credentials['sealed_storage'] == true,
      plugins: [
        for (final p in map['plugins'] as List? ?? const [])
          SecurityPluginItem.fromMap(Map<String, dynamic>.from(p as Map)),
      ],
      tokenAnomalyEnabled: tokenAnomaly['enabled'] == true,
      quarantinesToday: (tokenAnomaly['quarantines_today'] as num?)?.toInt() ?? 0,
      maxQuarantinesPerDay:
          (tokenAnomaly['max_quarantines_per_day'] as num?)?.toInt() ?? 0,
      tokenSkillStats: [
        for (final s in tokenAnomaly['skills'] as List? ?? const [])
          SkillTokenStat.fromMap(Map<String, dynamic>.from(s as Map)),
      ],
      rateWindowSec: (rate['window_sec'] as num?)?.toInt() ?? 0,
      rateMaxEvents: (rate['max_events'] as num?)?.toInt() ?? 0,
      guardBlockedTurns: (guard['blocked_turns'] as num?)?.toInt() ?? 0,
      guardSanitizedTurns: (guard['sanitized_turns'] as num?)?.toInt() ?? 0,
      auditTotal: (audit['total_in_memory'] as num?)?.toInt() ?? 0,
      auditRecent: [
        for (final e in audit['recent'] as List? ?? const [])
          Map<String, dynamic>.from(e as Map),
      ],
      activeSessions: (map['active_sessions'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Satu plugin pada Security Center: ringkasan consent (GUI-P1-10).
class SecurityPluginItem {
  const SecurityPluginItem({
    required this.id,
    this.registered = false,
    this.pending = false,
    this.grantedCount = 0,
    this.requestedCount = 0,
  });

  final String id;
  final bool registered;
  final bool pending;
  final int grantedCount;
  final int requestedCount;

  factory SecurityPluginItem.fromMap(Map<String, dynamic> map) =>
      SecurityPluginItem(
        id: '${map['id'] ?? ''}',
        registered: map['registered'] == true,
        pending: map['pending'] == true,
        grantedCount: (map['granted_count'] as num?)?.toInt() ?? 0,
        requestedCount: (map['requested_count'] as num?)?.toInt() ?? 0,
      );
}

/// Statistik baseline token per skill dari TokenAnomalyDetector (E1).
class SkillTokenStat {
  const SkillTokenStat({
    required this.slug,
    this.samples = 0,
  });

  final String slug;
  final int samples;

  factory SkillTokenStat.fromMap(Map<String, dynamic> map) => SkillTokenStat(
        slug: '${map['slug'] ?? ''}',
        samples: (map['samples'] as num?)?.toInt() ?? 0,
      );
}

/// Satu entri audit hasil query browser (GUI-P1-11) — sudah teredaksi
/// server-side via SecretRedactor.
class AuditEntry {
  const AuditEntry({
    required this.ts,
    this.session = '-',
    this.tool = '-',
    this.args = const {},
    this.risk = '-',
    this.verdict = '-',
    this.result,
    this.durationMs,
    this.error,
    this.taint = false,
  });

  final String ts;
  final String session;
  final String tool;
  final Map<String, dynamic> args;
  final String risk;
  final String verdict;
  final String? result;
  final int? durationMs;
  final String? error;
  final bool taint;

  factory AuditEntry.fromMap(Map<String, dynamic> map) => AuditEntry(
        ts: '${map['ts'] ?? '-'}',
        session: '${map['session'] ?? '-'}',
        tool: '${map['tool'] ?? '-'}',
        args: map['args'] is Map
            ? Map<String, dynamic>.from(map['args'] as Map)
            : const {},
        risk: '${map['risk'] ?? '-'}',
        verdict: '${map['verdict'] ?? '-'}',
        result: map['result'] == null ? null : '${map['result']}',
        durationMs: (map['duration_ms'] as num?)?.toInt(),
        error: map['error'] == null ? null : '${map['error']}',
        taint: map['taint'] == true,
      );
}

/// Hasil query audit (GUI-P1-11): halaman entri + total semua yang cocok.
class AuditQueryResult {
  const AuditQueryResult({
    this.entries = const [],
    this.total = 0,
  });

  final List<AuditEntry> entries;
  final int total;

  factory AuditQueryResult.fromMap(Map<String, dynamic> map) =>
      AuditQueryResult(
        entries: [
          for (final e in map['entries'] as List? ?? const [])
            AuditEntry.fromMap(Map<String, dynamic>.from(e as Map)),
        ],
        total: (map['total'] as num?)?.toInt() ?? 0,
      );
}

/// Satu file workspace untuk Artifacts browser (GUI-P2-04).
class ArtifactFileInfo {
  const ArtifactFileInfo({
    required this.path,
    this.bytes = 0,
    this.modified = '-',
  });

  final String path;
  final int bytes;
  final String modified;

  factory ArtifactFileInfo.fromMap(Map<String, dynamic> map) =>
      ArtifactFileInfo(
        path: '${map['path'] ?? ''}',
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        modified: '${map['modified'] ?? '-'}',
      );
}

/// Daftar file artifacts (GUI-P2-04) + flag truncation listing.
class ArtifactsListing {
  const ArtifactsListing({
    this.files = const [],
    this.truncated = false,
  });

  final List<ArtifactFileInfo> files;
  final bool truncated;

  factory ArtifactsListing.fromMap(Map<String, dynamic> map) =>
      ArtifactsListing(
        files: [
          for (final f in map['files'] as List? ?? const [])
            ArtifactFileInfo.fromMap(Map<String, dynamic>.from(f as Map)),
        ],
        truncated: map['truncated'] == true,
      );
}

/// Isi file teks yang dibaca (GUI-P2-04) — read-only, terpotong di
/// maxBytes server; file biner ditandai tanpa konten.
class ArtifactContent {
  const ArtifactContent({
    required this.path,
    this.bytes = 0,
    this.binary = false,
    this.truncated = false,
    this.content = '',
    this.bakExists = false,
  });

  final String path;
  final int bytes;
  final bool binary;
  final bool truncated;
  final String content;
  final bool bakExists;

  factory ArtifactContent.fromMap(Map<String, dynamic> map) =>
      ArtifactContent(
        path: '${map['path'] ?? ''}',
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        binary: map['binary'] == true,
        truncated: map['truncated'] == true,
        content: map['content'] == null ? '' : '${map['content']}',
        bakExists: map['bak_exists'] == true,
      );
}

/// Satu baris diff (GUI-P2-04): '=' konteks, '-' baris lama, '+' baru.
class DiffLine {
  const DiffLine({required this.type, this.text = ''});

  final String type;
  final String text;

  factory DiffLine.fromMap(Map<String, dynamic> map) =>
      DiffLine(type: '${map['type'] ?? '='}', text: '${map['text'] ?? ''}');
}

/// Hasil diff file vs `.bak` (GUI-P2-04) — read-only dari runtime.
class ArtifactDiff {
  const ArtifactDiff({
    required this.path,
    this.oldExists = false,
    this.newExists = false,
    this.lines = const [],
    this.truncated = false,
  });

  final String path;
  final bool oldExists;
  final bool newExists;
  final List<DiffLine> lines;
  final bool truncated;

  factory ArtifactDiff.fromMap(Map<String, dynamic> map) => ArtifactDiff(
        path: '${map['path'] ?? ''}',
        oldExists: map['old_exists'] == true,
        newExists: map['new_exists'] == true,
        lines: [
          for (final l in map['lines'] as List? ?? const [])
            DiffLine.fromMap(Map<String, dynamic>.from(l as Map)),
        ],
        truncated: map['truncated'] == true,
      );
}

/// Run-inspector (GUI-P2-04): satu langkah tool dalam run agent.
class RunStepEntry {
  const RunStepEntry({
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

  factory RunStepEntry.fromMap(Map<String, dynamic> map) => RunStepEntry(
        tool: '${map['tool'] ?? ''}',
        verdict: '${map['verdict'] ?? ''}',
        isError: map['is_error'] == true,
        durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
        at: '${map['at'] ?? ''}',
      );
}

/// Run-inspector (GUI-P2-04): satu run agent (turn) aktif atau riwayat.
class RunEntry {
  const RunEntry({
    required this.id,
    required this.session,
    required this.channel,
    required this.subagent,
    required this.parent,
    required this.input,
    required this.state,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
    required this.success,
    required this.tokensUsed,
    required this.toolCalls,
    required this.answer,
    required this.error,
    required this.steps,
  });
  final String id;
  final String session;
  final String channel;
  final bool subagent;
  final String? parent;
  final String input;
  final String state;
  final String startedAt;
  final String? endedAt;
  final int? durationMs;
  final bool? success;
  final int tokensUsed;
  final int toolCalls;
  final String? answer;
  final String? error;
  final List<RunStepEntry> steps;

  bool get running => state == 'running';

  factory RunEntry.fromMap(Map<String, dynamic> map) => RunEntry(
        id: '${map['id'] ?? ''}',
        session: '${map['session'] ?? ''}',
        channel: '${map['channel'] ?? ''}',
        subagent: map['subagent'] == true,
        parent: map['parent'] == null ? null : '${map['parent']}',
        input: '${map['input'] ?? ''}',
        state: '${map['state'] ?? 'running'}',
        startedAt: '${map['started_at'] ?? ''}',
        endedAt: map['ended_at'] == null ? null : '${map['ended_at']}',
        durationMs: (map['duration_ms'] as num?)?.toInt(),
        success: map['success'] == null ? null : map['success'] == true,
        tokensUsed: (map['tokens_used'] as num?)?.toInt() ?? 0,
        toolCalls: (map['tool_calls'] as num?)?.toInt() ?? 0,
        answer: map['answer'] == null ? null : '${map['answer']}',
        error: map['error'] == null ? null : '${map['error']}',
        steps: [
          for (final s in map['steps'] as List? ?? const [])
            RunStepEntry.fromMap(Map<String, dynamic>.from(s as Map)),
        ],
      );
}

/// Memory Explorer (GUI-P1-12): satu file kurasi (MEMORY.md / USER.md).
class CuratedFileInfo {
  const CuratedFileInfo({this.text = '', this.chars = 0});
  final String text;
  final int chars;

  factory CuratedFileInfo.fromMap(Map<String, dynamic> map) => CuratedFileInfo(
        text: '${map['text'] ?? ''}',
        chars: (map['chars'] as num?)?.toInt() ?? 0,
      );
}

/// Memory Explorer (GUI-P1-12): snapshot kurasi + anggaran karakter.
class CuratedMemoryInfo {
  const CuratedMemoryInfo({
    this.memory = const CuratedFileInfo(),
    this.user = const CuratedFileInfo(),
    this.budget = 0,
    this.used = 0,
  });
  final CuratedFileInfo memory;
  final CuratedFileInfo user;
  final int budget;
  final int used;

  factory CuratedMemoryInfo.fromMap(Map<String, dynamic> map) =>
      CuratedMemoryInfo(
        memory: CuratedFileInfo.fromMap(
            Map<String, dynamic>.from(map['memory'] as Map? ?? const {})),
        user: CuratedFileInfo.fromMap(
            Map<String, dynamic>.from(map['user'] as Map? ?? const {})),
        budget: (map['budget'] as num?)?.toInt() ?? 0,
        used: (map['used'] as num?)?.toInt() ?? 0,
      );
}

/// Memory Explorer (GUI-P1-12): satu entri memori berlapis.
class LayerEntry {
  const LayerEntry({
    required this.id,
    this.layer = 'semantic',
    this.text = '',
    this.importance = 0,
    this.tags = const [],
    this.accessCount = 0,
    this.createdAt = '',
    this.lastAccessedAt = '',
    this.ownerKey = '',
    this.sourceSession = '',
  });
  final String id;
  final String layer;
  final String text;
  final double importance;
  final List<String> tags;
  final int accessCount;
  final String createdAt;
  final String lastAccessedAt;
  final String ownerKey;
  final String sourceSession;

  factory LayerEntry.fromMap(Map<String, dynamic> map) => LayerEntry(
        id: '${map['id'] ?? ''}',
        layer: '${map['layer'] ?? 'semantic'}',
        text: '${map['text'] ?? ''}',
        importance: (map['importance'] as num?)?.toDouble() ?? 0,
        tags: [
          for (final t in map['tags'] as List? ?? const []) '$t',
        ],
        accessCount: (map['access_count'] as num?)?.toInt() ?? 0,
        createdAt: '${map['created_at'] ?? ''}',
        lastAccessedAt: '${map['last_accessed_at'] ?? ''}',
        ownerKey: '${map['owner_key'] ?? ''}',
        sourceSession: '${map['source_session'] ?? ''}',
      );
}

/// Per-lapisan: jumlah entri + rata-rata skor importance.
class LayerStats {
  const LayerStats({this.count = 0, this.avgScore = 0});
  final int count;
  final double avgScore;

  factory LayerStats.fromMap(Map<String, dynamic> map) => LayerStats(
        count: (map['count'] as num?)?.toInt() ?? 0,
        avgScore: (map['avg_score'] as num?)?.toDouble() ?? 0,
      );
}

/// Memory Explorer (GUI-P1-12): snapshot entri berlapis + stats.
class LayersSnapshot {
  const LayersSnapshot({
    this.stats = const {},
    this.entries = const [],
    this.total = 0,
    this.truncated = false,
  });
  final Map<String, LayerStats> stats;
  final List<LayerEntry> entries;
  final int total;
  final bool truncated;

  factory LayersSnapshot.fromMap(Map<String, dynamic> map) => LayersSnapshot(
        stats: {
          for (final e in (map['stats'] as Map? ?? const {}).entries)
            '${e.key}': LayerStats.fromMap(
                Map<String, dynamic>.from(e.value as Map? ?? const {})),
        },
        entries: [
          for (final e in map['entries'] as List? ?? const [])
            LayerEntry.fromMap(Map<String, dynamic>.from(e as Map)),
        ],
        total: (map['total'] as num?)?.toInt() ?? 0,
        truncated: map['truncated'] == true,
      );
}

/// Memory Explorer (GUI-P1-12): satu dokumen sumber RAG.
class RagDocInfo {
  const RagDocInfo({
    this.docId = '',
    this.chunks = 0,
    this.chars = 0,
    this.preview = '',
  });
  final String docId;
  final int chunks;
  final int chars;
  final String preview;

  factory RagDocInfo.fromMap(Map<String, dynamic> map) => RagDocInfo(
        docId: '${map['doc_id'] ?? ''}',
        chunks: (map['chunks'] as num?)?.toInt() ?? 0,
        chars: (map['chars'] as num?)?.toInt() ?? 0,
        preview: '${map['preview'] ?? ''}',
      );
}

/// Memory Explorer (GUI-P1-12): snapshot sumber RAG grouped per dokumen.
class RagSourcesInfo {
  const RagSourcesInfo({
    this.chunkCount = 0,
    this.docs = const [],
    this.truncated = false,
  });
  final int chunkCount;
  final List<RagDocInfo> docs;
  final bool truncated;

  factory RagSourcesInfo.fromMap(Map<String, dynamic> map) => RagSourcesInfo(
        chunkCount: (map['chunk_count'] as num?)?.toInt() ?? 0,
        docs: [
          for (final d in map['docs'] as List? ?? const [])
            RagDocInfo.fromMap(Map<String, dynamic>.from(d as Map)),
        ],
        truncated: map['truncated'] == true,
      );
}

/// Run-inspector (GUI-P2-04): snapshot {active, recent, truncated}.
class RunsSnapshot {
  const RunsSnapshot({
    required this.active,
    required this.recent,
    required this.truncated,
    this.cost,
  });
  final List<RunEntry> active;
  final List<RunEntry> recent;
  final bool truncated;

  /// F7 — agregasi biaya/token per user/channel/day (`/v1/runs` `cost`).
  final CostSummary? cost;

  factory RunsSnapshot.fromMap(Map<String, dynamic> map) => RunsSnapshot(
        active: [
          for (final r in map['active'] as List? ?? const [])
            RunEntry.fromMap(Map<String, dynamic>.from(r as Map)),
        ],
        recent: [
          for (final r in map['recent'] as List? ?? const [])
            RunEntry.fromMap(Map<String, dynamic>.from(r as Map)),
        ],
        truncated: map['truncated'] == true,
        cost: map['cost'] is Map
            ? CostSummary.fromMap(Map<String, dynamic>.from(map['cost'] as Map))
            : null,
      );
}

/// F7 — agregasi cost/token (window UTC `days` hari) per bucket.
class CostSummary {
  const CostSummary({
    required this.groupBy,
    required this.days,
    required this.totalTurns,
    required this.totalTokensUsed,
    required this.totalToolCalls,
    required this.totalSuccess,
    required this.buckets,
  });

  final String groupBy;
  final int days;
  final int totalTurns;
  final int totalTokensUsed;
  final int totalToolCalls;
  final int totalSuccess;

  /// Urut token terbesar dulu.
  final List<CostSummaryBucket> buckets;

  factory CostSummary.fromMap(Map<String, dynamic> map) {
    final total = Map<String, dynamic>.from(map['total'] as Map? ?? const {});
    return CostSummary(
      groupBy: map['group_by']?.toString() ?? 'user',
      days: map['days'] is int ? map['days'] as int : 7,
      totalTurns: total['turns'] is int ? total['turns'] as int : 0,
      totalTokensUsed:
          total['tokens_used'] is int ? total['tokens_used'] as int : 0,
      totalToolCalls:
          total['tool_calls'] is int ? total['tool_calls'] as int : 0,
      totalSuccess: total['success'] is int ? total['success'] as int : 0,
      buckets: [
        for (final b in map['buckets'] as List? ?? const [])
          CostSummaryBucket.fromMap(Map<String, dynamic>.from(b as Map)),
      ],
    );
  }
}

class CostSummaryBucket {
  const CostSummaryBucket({
    required this.key,
    required this.turns,
    required this.tokensUsed,
    required this.toolCalls,
    required this.success,
  });

  final String key;
  final int turns;
  final int tokensUsed;
  final int toolCalls;
  final int success;

  factory CostSummaryBucket.fromMap(Map<String, dynamic> map) =>
      CostSummaryBucket(
        key: map['key']?.toString() ?? '',
        turns: map['turns'] is int ? map['turns'] as int : 0,
        tokensUsed: map['tokens_used'] is int ? map['tokens_used'] as int : 0,
        toolCalls: map['tool_calls'] is int ? map['tool_calls'] as int : 0,
        success: map['success'] is int ? map['success'] as int : 0,
      );
}
