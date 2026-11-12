import 'dart:convert';

/// Normalized inbound message from any gateway.
class InboundMessage {
  const InboundMessage({
    required this.channel,
    required this.userKey,
    required this.sessionKey,
    required this.text,
    this.attachments = const [],
    this.meta = const {},
  });

  final String channel; // cli | telegram | discord | email | http | scheduler
  final String userKey;
  final String sessionKey;
  final String text;
  final List<Attachment> attachments;
  final Map<String, Object?> meta;
}

class Attachment {
  const Attachment({required this.type, required this.urlOrBytes, this.mime});
  final String type; // image | audio | document
  final Object urlOrBytes;
  final String? mime;
}

class OutboundMessage {
  const OutboundMessage({
    required this.sessionKey,
    required this.text,
    this.markdown = true,
    this.buttons = const [],
    this.meta = const {},
  });

  final String sessionKey;
  final String text;
  final bool markdown;
  final List<ConfirmButton> buttons;
  final Map<String, Object?> meta;
}

class ConfirmButton {
  const ConfirmButton({required this.id, required this.label});
  final String id;
  final String label;
}

class Session {
  Session({
    required this.id,
    required this.channel,
    required this.userKey,
    this.title,
    this.summary,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String channel;
  final String userKey;
  String? title;
  String? summary;
  final DateTime createdAt;
  DateTime updatedAt;
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolCalls,
    this.name,
  });

  final String role; // system | user | assistant | tool
  final String content;
  final String? toolCallId;
  final List<ToolCall>? toolCalls;
  final String? name;

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (toolCallId != null) 'tool_call_id': toolCallId,
    if (name != null) 'name': name,
    if (toolCalls != null)
      'tool_calls': toolCalls!.map((c) => c.toJson()).toList(),
  };
}

/// Trust classification shared by the agent loop and security sanitizer.
/// External data can taint the session; local workspace output is still
/// isolated as untrusted content, but does not trigger the same external-data
/// confirmation rule on every subsequent medium-risk operation.
class ToolTrust {
  const ToolTrust._();

  static bool isExternalTaintSource(String name) =>
      name == 'web_fetch' ||
      name == 'web_search' ||
      name == 'http_request' ||
      name == 'cdp_browser' ||
      name.startsWith('mcp_') ||
      name.startsWith('script_');

  static bool isUntrustedOutput(String name) =>
      isExternalTaintSource(name) ||
      const {'read_file', 'list_dir', 'grep', 'probe', 'shell'}.contains(name);
}

class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.risk = 'low',
    this.timeoutSec = 30,
    this.maxOutputChars = 20000,
    this.parallelSafe = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String risk; // low | medium | high | critical
  final int timeoutSec;
  final int maxOutputChars;

  /// True only for side-effect-free operations explicitly audited for safe
  /// concurrent execution. Unknown/custom tools remain serialized.
  final bool parallelSafe;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parameters': inputSchema,
  };
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.args});

  final String id;
  final String name;
  final Map<String, dynamic> args;

  String get argsHash {
    final sorted = jsonEncode(args);
    return sorted.hashCode.toRadixString(16);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': jsonEncode(args)},
  };

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final fn = json['function'] as Map<String, dynamic>? ?? json;
    final argsRaw = fn['arguments'];
    Map<String, dynamic> args;
    if (argsRaw is String) {
      args = jsonDecode(argsRaw) as Map<String, dynamic>;
    } else if (argsRaw is Map) {
      args = Map<String, dynamic>.from(argsRaw);
    } else {
      args = {};
    }
    return ToolCall(
      id:
          json['id'] as String? ??
          'call_${DateTime.now().millisecondsSinceEpoch}',
      name: fn['name'] as String? ?? '',
      args: args,
    );
  }
}

class ToolResult {
  const ToolResult({
    required this.callId,
    required this.content,
    this.isError = false,
    this.durationMs,
  });

  final String callId;
  final String content;
  final bool isError;
  final int? durationMs;

  factory ToolResult.denied(PermissionResult verdict) => ToolResult(
    callId: '',
    content: 'Denied: ${verdict.reason ?? verdict.verdict.name}',
    isError: true,
  );
}

/// Permission verdict returned by a PermissionGate.
enum PermissionVerdict { allowed, denied, needsConfirm }

class PermissionResult {
  const PermissionResult(this.verdict, {this.reason, this.confirmId});

  final PermissionVerdict verdict;
  final String? reason;
  final String? confirmId;
}

class ToolContext {
  const ToolContext({
    required this.session,
    required this.workspacePath,
    this.tainted = false,
  });

  final Session session;
  final String workspacePath;
  final bool tainted;
}

class TokenUsage {
  const TokenUsage({this.prompt = 0, this.completion = 0, this.total = 0});
  final int prompt;
  final int completion;
  final int total;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
    prompt: prompt + other.prompt,
    completion: completion + other.completion,
    total: total + other.total,
  );
}

class Message {
  Message({
    required this.sessionId,
    required this.role,
    required this.content,
    this.toolName,
    this.tokens,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String sessionId;
  final String role;
  final String content;
  final String? toolName;
  final int? tokens;
  final DateTime createdAt;
}

/// Trust origin of a memory / context chunk (PRD §9.1).
enum Provenance {
  user,
  trustedConfig,
  localFile,
  web,
  email,
  mcp,
  memory,
  agent,
  unknown,
}

class Fact {
  const Fact({
    required this.id,
    required this.text,
    this.kind = 'fact',
    this.importance = 0.5,
    this.sourceSession,
    this.ownerKey,
    this.createdAt,
    this.provenance = Provenance.unknown,
    this.confidence = 0.7,
    this.ttlDays,
    this.state = 'active',
  });

  final String id;
  final String text;
  final String kind; // fact | preference | episode
  final double importance;
  final String? sourceSession;
  /// Stable local profile/user scope. Null means legacy/unassigned and must
  /// never be returned by owner-scoped retrieval.
  final String? ownerKey;
  /// UTC creation time, used to enforce TTL. Null is legacy data.
  final DateTime? createdAt;
  final Provenance provenance;
  final double confidence;
  final int? ttlDays;
  final String state; // candidate | pending | active | rejected

  /// Untrusted sources must not escalate privilege.
  bool get isUntrusted => switch (provenance) {
        Provenance.trustedConfig || Provenance.user => false,
        Provenance.localFile ||
        Provenance.web ||
        Provenance.email ||
        Provenance.mcp ||
        Provenance.memory ||
        Provenance.agent ||
        Provenance.unknown => true,
      };

  static Provenance provenanceFromName(Object? value) {
    if (value is! String) return Provenance.unknown;
    return Provenance.values.firstWhere(
      (item) => item.name == value,
      orElse: () => Provenance.unknown,
    );
  }

  bool isExpiredAt(DateTime now) => ttlDays != null &&
      createdAt != null &&
      !createdAt!.toUtc().add(Duration(days: ttlDays!)).isAfter(now.toUtc());

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'kind': kind,
        'importance': importance,
        'source_session': sourceSession,
        'owner_key': ownerKey,
        'created_at': createdAt?.toUtc().toIso8601String(),
        'provenance': provenance.name,
        'confidence': confidence,
        'ttl_days': ttlDays,
        'state': state,
      };
}

class MemoryHit {
  const MemoryHit({
    required this.id,
    required this.text,
    required this.score,
    this.provenance = Provenance.unknown,
    this.confidence = 0.5,
    this.state = 'active',
    this.ttlDays,
    this.ownerKey,
    this.createdAt,
  });

  final String id;
  final String text;
  final double score;
  final Provenance provenance;
  final double confidence;
  final String state;
  final int? ttlDays;
  final String? ownerKey;
  final DateTime? createdAt;

  bool isExpiredAt(DateTime now) => ttlDays != null &&
      createdAt != null &&
      !createdAt!.toUtc().add(Duration(days: ttlDays!)).isAfter(now.toUtc());

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'score': score,
        'provenance': provenance.name,
        'confidence': confidence,
        'state': state,
        if (ttlDays != null) 'ttl_days': ttlDays,
        if (ownerKey != null) 'owner_key': ownerKey,
        if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
      };
}

class VectorHit {
  const VectorHit({
    required this.id,
    required this.score,
    this.meta = const {},
  });
  final String id;
  final double score;
  final Map<String, Object?> meta;
}

/// Collected response from one LLM turn.
class LlmResponse {
  LlmResponse({
    this.text = '',
    this.toolCalls = const [],
    this.usage = const TokenUsage(),
    this.finishReason = 'stop',
  });

  String text;
  List<ToolCall> toolCalls;
  TokenUsage usage;
  String finishReason;
}
