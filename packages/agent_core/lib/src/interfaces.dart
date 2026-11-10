import 'dart:async';

import 'models.dart';

/// Capabilities detected per model (P-06).
class Capabilities {
  const Capabilities({
    this.toolCalling = false,
    this.vision = false,
    this.logprobs = false,
    this.streaming = true,
    this.jsonSchemaOutput = false,
    this.maxContext = 8192,
  });

  final bool toolCalling;
  final bool vision;
  final bool logprobs;
  final bool streaming;
  final bool jsonSchemaOutput;
  final int maxContext;
}

/// Events emitted by an [LlmProvider] during chat.
sealed class LlmEvent {
  const LlmEvent();
}

class LlmTextDelta extends LlmEvent {
  const LlmTextDelta(this.delta);
  final String delta;
}

class LlmToolCall extends LlmEvent {
  const LlmToolCall(this.call);
  final ToolCall call;
}

class LlmUsage extends LlmEvent {
  const LlmUsage(this.usage);
  final TokenUsage usage;
}

class LlmDone extends LlmEvent {
  const LlmDone({this.finishReason = 'stop'});
  final String finishReason;
}

class LlmError extends LlmEvent {
  const LlmError(this.message, {this.code});
  final String message;
  final String? code;
}

/// OpenAI-compatible style request.
class ChatRequest {
  const ChatRequest({
    required this.messages,
    this.tools = const [],
    this.toolChoice,
    this.maxTokens,
    this.temperature,
    this.stream = true,
    this.model,
  });

  final List<ChatMessage> messages;
  final List<ToolSpec> tools;
  final String? toolChoice; // auto | none | required | specific name
  final int? maxTokens;
  final double? temperature;
  final bool stream;
  final String? model;
}

/// Abstract LLM chat provider (provider-agnostic, P-01).
abstract class LlmProvider {
  String get id;
  Capabilities get capabilities;

  /// Streaming chat. Collects into a complete response when needed.
  Stream<LlmEvent> chat(ChatRequest req);

  /// Optional embedding. Returns empty list if unsupported.
  Future<List<double>> embed(String text) async => const [];
}

/// Typed decision questions (Choice / Score / Noul).
sealed class Question {
  Map<String, dynamic> toJson();
}

class ChoiceQuestion extends Question {
  ChoiceQuestion(this.options, {this.criteria});
  final List<String> options;
  final String? criteria;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'choice',
    'options': options,
    if (criteria != null) 'criteria': criteria,
  };
}

class ScoreQuestion extends Question {
  ScoreQuestion({this.min = 0, this.max = 1, this.criteria});
  final double min;
  final double max;
  final String? criteria;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'score',
    'min': min,
    'max': max,
    if (criteria != null) 'criteria': criteria,
  };
}

class NoulQuestion extends Question {
  NoulQuestion({this.criteria});
  final String? criteria;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'noul',
    if (criteria != null) 'criteria': criteria,
  };
}

class DecisionResult {
  const DecisionResult(this.answers);
  final Map<String, Answer> answers;

  factory DecisionResult.fromJson(Map<String, dynamic> json) {
    final raw = json['answers'] as Map<String, dynamic>? ?? {};
    final answers = <String, Answer>{};
    for (final e in raw.entries) {
      answers[e.key] = Answer.fromJson(e.value as Map<String, dynamic>);
    }
    return DecisionResult(answers);
  }
}

class Answer {
  const Answer({
    required this.type,
    this.choice,
    this.score,
    this.noul,
    this.probabilities = const {},
    this.confidence = 0.0,
  });

  final String type; // choice | score | noul
  final String? choice;
  final double? score;
  final double? noul; // P(yes)
  final Map<String, double> probabilities;
  final double confidence;

  factory Answer.fromJson(Map<String, dynamic> json) {
    return Answer(
      type: json['type'] as String? ?? 'unknown',
      choice: json['choice'] as String?,
      score: (json['score'] as num?)?.toDouble(),
      noul:
          (json['noul'] as num?)?.toDouble() ??
          (json['probabilities'] is Map
              ? (json['probabilities']['yes'] as num?)?.toDouble()
              : null),
      probabilities:
          (json['probabilities'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, (v as num).toDouble()),
          ) ??
          const {},
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Decision model (Jev / Laya / LLM-JSON fallback). Not a chat model.
abstract class DecisionProvider {
  Future<DecisionResult> decide(String state, Map<String, Question> questions);
}

/// Tool contract.
abstract class Tool {
  ToolSpec get spec;
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx);
}

/// Runs a registered tool by name.
abstract class ToolExecutor {
  Future<ToolResult> run(ToolCall call, ToolContext ctx);
}

/// Memory store interface.
abstract class MemoryStore {
  Future<void> addMessage(Message m);
  Future<List<MemoryHit>> search(String query, {int k = 8});
  Future<void> upsertFact(Fact f);

  /// Called after a successful agent turn (optional).
  Future<void> afterTurn(Session session) async {}
}

/// Optional strict owner-scoped retrieval contract. Callers must not fall back
/// to unscoped search when this interface is unavailable.
abstract interface class OwnerScopedMemoryStore {
  Future<List<MemoryHit>> searchForOwner(
    String query, {
    required String ownerKey,
    int k = 8,
  });
}

/// Vector index (brute-force first, sqlite-vec later).
abstract class VectorIndex {
  Future<void> upsert(String id, List<double> v, Map<String, Object?> meta);
  Future<List<VectorHit>> topK(List<double> q, int k);
}

/// Gateway for inbound/outbound messages.
abstract class Gateway {
  String get channel;
  Stream<InboundMessage> get inbound;
  Future<void> send(OutboundMessage m);
  Future<void> sendTyping(String sessionKey);

  /// Releases resources owned by the gateway (streams, sockets, child
  /// processes). Implementations that own such resources must override this;
  /// the default no-op keeps simple adapters compiling.
  Future<void> close() async {}
}

abstract class PermissionGate {
  Future<PermissionResult> check(ToolCall call, Session session);
}

/// Route decision from the tiered router.
class RouteDecision {
  const RouteDecision({
    required this.llm,
    this.tier = 2,
    this.needTools = false,
    this.risk = 'low',
    this.complexity = 'sedang',
    this.providerId = '',
    this.reason = '',
    this.fallbackIds = const [],
    this.score = 0.0,
  });

  final LlmProvider llm;
  final int tier;
  final bool needTools;
  final String risk;
  final String complexity;
  /// Selected provider id for explain/trace.
  final String providerId;
  /// Human-readable routing reason.
  final String reason;
  /// Ordered fallback provider ids if primary fails.
  final List<String> fallbackIds;
  final double score;

  Map<String, dynamic> toJson() => {
        'provider_id': providerId,
        'tier': tier,
        'need_tools': needTools,
        'risk': risk,
        'complexity': complexity,
        'reason': reason,
        'fallback_ids': fallbackIds,
        'score': score,
      };
}

/// Sanitizes content that crosses a trust boundary (PRD §12): secret redaction,
/// untrusted-data wrapping, delimiter neutralisation. Implemented in
/// `agent_security` (`SecuritySanitizer`).
abstract class ContentSanitizer {
  /// Applied to every tool result before it is shown to the model.
  String toolResult(ToolCall call, String content);

  /// Applied to every model/agent output before it is shown to a user or stored.
  String output(String text);
}

/// Lightweight session metadata (PRD §8 `Session`).
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.channel,
    required this.userKey,
    required this.updatedAt,
    this.title,
    this.turns = 0,
  });

  final String id;
  final String channel;
  final String userKey;
  final DateTime updatedAt;
  final String? title;
  final int turns;

  Map<String, dynamic> toJson() => {
        'id': id,
        'channel': channel,
        'user': userKey,
        'title': title,
        'turns': turns,
        'updated_at': updatedAt.toIso8601String(),
      };
}

/// Persistent conversation history shared by CLI, daemon, API and gateways
/// (PRD §8, acceptance criteria 4 and 12). Implementations must survive restart.
abstract class SessionStore {
  /// Returns the existing session or creates and persists a new one.
  Future<Session> getOrCreate(
    String sessionId, {
    required String channel,
    required String userKey,
  });

  /// Most recent [limit] user/assistant messages, oldest first.
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20});

  Future<void> appendTurn(
    String sessionId, {
    required String user,
    required String assistant,
    List<String> tools = const [],
  });

  Future<List<SessionInfo>> list();

  /// Removes a session; returns false when it did not exist.
  Future<bool> delete(String sessionId);
}
