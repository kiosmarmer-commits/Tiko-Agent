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
    this.serviceTier,
    this.reasoningEffort,
  });

  final List<ChatMessage> messages;
  final List<ToolSpec> tools;
  final String? toolChoice; // auto | none | required | specific name
  final int? maxTokens;
  final double? temperature;
  final bool stream;
  final String? model;

  /// Hermes fast mode (`agent/fast_mode.py`): tier wire opsional per request
  /// (`service_tier` OpenAI-compat) — hanya terisi saat jendela fast
  /// terbuka/tier static; null = normal (byte-identical dengan request
  /// biasa, prompt cache tidak terganggu).
  final String? serviceTier;

  /// Hermes `agent/reasoning_effort.py`: effort reasoning opsional per
  /// request (`none..ultra`; kosong/null = field TIDAK dikirim ke wire —
  /// tidak pernah dikarang). Provider meng-clamp ke kosakata wire-nya via
  /// [clampEffort]; bentuk wire (`reasoning_effort` / `reasoning.effort` /
  /// `thinking.budget_tokens`) tetap lokal di provider.
  final String? reasoningEffort;
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
    this.model,
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
  /// Nama model yang dipilih untuk sesi metadata (kosong bila tak diketahui).
  final String? model;
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

  /// Applied to tool-call arguments before they are logged, stored, or
  /// forwarded to learning/telemetry sinks. Defaults to a passthrough.
  Map<String, dynamic> sanitizeArgs(Map<String, dynamic> args) =>
      Map<String, dynamic>.of(args);
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
    this.provider,
    this.model,
    this.pinned = false,
    this.archived = false,
    this.lastFailed = false,
    this.createdAt,
  });

  final String id;
  final String channel;
  final String userKey;
  final DateTime updatedAt;
  final String? title;
  final int turns;

  /// Metadata turn terakhir (Hermes S6): provider dan model yang dipakai.
  final String? provider;
  final String? model;

  /// Filter/organisasi history (Hermes S6): penanda pin, arsip, dan apakah
  /// turn terakhir gagal.
  final bool pinned;
  final bool archived;
  final bool lastFailed;

  /// Filter artifacts per session (Hermes S7): time of session creation,
  /// used to hide files from before the session started.
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'channel': channel,
        'user': userKey,
        'title': title,
        'turns': turns,
        if (provider != null) 'provider': provider,
        if (model != null) 'model': model,
        'pinned': pinned,
        'archived': archived,
        'last_failed': lastFailed,
        'updated_at': updatedAt.toIso8601String(),
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
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
    String? provider,
    String? model,
  });

  Future<List<SessionInfo>> list();

  /// Removes a session; returns false when it did not exist.
  Future<bool> delete(String sessionId);

  /// Sets a human-readable title for a session; returns false when the
  /// session does not exist, the store does not support renaming, or the
  /// title is empty.
  Future<bool> rename(String sessionId, String title) async => false;

  /// Hermes S6: pin/unpin sesi agar selalu tampil paling atas di history.
  Future<bool> setPinned(String sessionId, bool pinned) async => false;

  /// Hermes S6: arsipkan/keluarkan dari arsip sesi (tidak dihapus).
  Future<bool> setArchived(String sessionId, bool archived) async => false;

  /// Hermes S6: salin sesi beserta seluruh pesannya ke sesi baru; return
  /// metadata sesi baru, null bila asal tak ada / store tak mendukung.
  Future<SessionInfo?> duplicate(
    String sessionId, {
    String? newId,
  }) async => null;

  /// Hermes S6: hapus banyak sesi sekaligus; return jumlah yang benar-benar
  /// terhapus.
  Future<int> deleteMany(List<String> sessionIds) async => 0;

  /// Hermes S6: catat hasil turn terakhir (sukses/gagal) + provider/model
  /// yang dipakai, untuk filter dan indikator status di history GUI.
  Future<bool> markTurnOutcome(
    String sessionId, {
    required bool ok,
    String? provider,
    String? model,
  }) async => false;

  /// Hermes S6: ambil satu sesi (metadata), null bila tidak ada.
  Future<SessionInfo?> get(String sessionId) async => null;

  /// Cross-conversation search over stored turns (P1: session search).
  /// Implementations without search support return an empty list.
  Future<List<SessionSearchHit>> searchSessions(
    String query, {
    int limit = 8,
  }) async => const <SessionSearchHit>[];

  /// Hermes `conversation_compression_manual`: ganti riwayat lama sesi
  /// dengan ringkasan [summary] dan pertahankan [keepLastMessages] pesan
  /// terakhir. Ringkasan juga disimpan di metadata sesi. Return false bila
  /// sesi tidak ada atau store tidak mendukung (fail-open: riwayat utuh).
  Future<bool> compactSession(
    String sessionId, {
    required String summary,
    int keepLastMessages = 6,
  }) async => false;
}

/// One cross-conversation search hit: the session it came from, the matching
/// message role, a redacted snippet around the first match, and a relevance
/// score (term frequency + recency).
class SessionSearchHit {
  const SessionSearchHit({
    required this.sessionId,
    required this.role,
    required this.snippet,
    required this.score,
    this.title,
    this.timestamp,
  });

  final String sessionId;
  final String role;
  final String snippet;
  final double score;
  final String? title;
  final DateTime? timestamp;

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'role': role,
        'snippet': snippet,
        'score': score,
        if (title != null) 'title': title,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
      };
}
