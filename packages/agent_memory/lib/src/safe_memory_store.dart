import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart';

/// Wraps any [MemoryStore] with secret redaction + provenance hygiene.
class SafeMemoryStore implements MemoryStore, OwnerScopedMemoryStore {
  SafeMemoryStore(this.inner, {ContentSanitizer? sanitizer})
      : sanitizer = sanitizer ?? SecuritySanitizer();

  final MemoryStore inner;
  final ContentSanitizer sanitizer;
  final _redactor = SecretRedactor();

  @override
  Future<void> addMessage(Message m) async {
    final cleaned = Message(
      sessionId: m.sessionId,
      role: m.role,
      content: _redactor.redact(m.content),
      toolName: m.toolName,
      tokens: m.tokens,
      createdAt: m.createdAt,
    );
    await inner.addMessage(cleaned);
  }

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async {
    if (k < 1) return const [];
    final hits = await inner.search(query, k: k * 8);
    return _filterTrusted(hits, k: k);
  }

  @override
  Future<List<MemoryHit>> searchForOwner(
    String query, {required String ownerKey, int k = 8}) async {
    if (ownerKey.trim().isEmpty || k < 1) return const [];
    final scoped = inner;
    if (scoped is! OwnerScopedMemoryStore) return const [];
    final hits = await (scoped as OwnerScopedMemoryStore).searchForOwner(
      query,
      ownerKey: ownerKey,
      k: k * 8,
    );
    return _filterTrusted(
      hits.where((hit) => hit.ownerKey == ownerKey).toList(),
      k: k,
    );
  }

  List<MemoryHit> _filterTrusted(List<MemoryHit> hits, {required int k}) {
    final now = DateTime.now().toUtc();
    return hits
        .where((hit) => hit.state == 'active' &&
            !hit.isExpiredAt(now) &&
            (hit.provenance == Provenance.user ||
                hit.provenance == Provenance.trustedConfig))
        .take(k)
        .map((hit) => MemoryHit(
              id: hit.id,
              text: _redactor.redact(hit.text),
              score: hit.score,
              provenance: hit.provenance,
              confidence: hit.confidence,
              state: hit.state,
              ttlDays: hit.ttlDays,
              ownerKey: hit.ownerKey,
              createdAt: hit.createdAt,
            ))
        .toList();
  }

  @override
  Future<void> upsertFact(Fact f) async {
    final text = _redactor.redact(f.text);
    // Strip instruction-like lines from untrusted provenance
    var safeText = text;
    if (f.isUntrusted) {
      safeText = _stripInstructionLike(text);
      safeText = sanitizer.toolResult(
        const ToolCall(id: 'mem', name: 'memory', args: {}),
        safeText,
      );
    }
    await inner.upsertFact(Fact(
      id: f.id,
      text: safeText,
      kind: f.kind,
      importance: f.isUntrusted
          ? (f.importance * 0.5).clamp(0.0, 0.4).toDouble()
          : f.importance,
      sourceSession: f.sourceSession,
      ownerKey: f.ownerKey,
      createdAt: f.createdAt ?? DateTime.now().toUtc(),
      provenance: f.provenance,
      confidence: f.isUntrusted
          ? f.confidence.clamp(0.0, 0.5).toDouble()
          : f.confidence,
      ttlDays: f.ttlDays ?? (f.isUntrusted ? 14 : null),
      state: f.state == 'active' && f.isUntrusted ? 'pending' : f.state,
    ));
  }

  @override
  Future<void> afterTurn(Session session) => inner.afterTurn(session);

  String _stripInstructionLike(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    for (final line in lines) {
      final l = line.trim().toLowerCase();
      if (l.startsWith('ignore previous') ||
          l.startsWith('system:') ||
          l.startsWith('you are now') ||
          l.contains('disregard all prior')) {
        out.add('[stripped-instruction]');
        continue;
      }
      out.add(line);
    }
    return out.join('\n');
  }
}
