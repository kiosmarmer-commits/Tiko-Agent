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
  });

  final String? defaultId;
  final List<ProviderItem> providers;
  final Map<String, String> tiers;
  final Map<String, String> sessionOverrides;

  factory ProvidersSnapshot.fromMap(Map<String, dynamic> map) {
    final tiers = Map<String, dynamic>.from(map['tiers'] as Map? ?? const {});
    final overrides = Map<String, dynamic>.from(
        map['session_overrides'] as Map? ?? const {});
    return ProvidersSnapshot(
      defaultId: map['default'] == null ? null : '${map['default']}',
      providers: [
        for (final p in map['providers'] as List? ?? const [])
          ProviderItem.fromMap(Map<String, dynamic>.from(p as Map)),
      ],
      tiers: {for (final e in tiers.entries) e.key: '${e.value}'},
      sessionOverrides: {for (final e in overrides.entries) e.key: '${e.value}'},
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
