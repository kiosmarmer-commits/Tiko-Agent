import 'package:agent_core/agent_core.dart';
import 'package:uuid/uuid.dart';

/// In-memory MemoryStore with simple token FTS + optional embeddings (M2 foundation).
///
/// Production path will swap to drift + SQLite FTS5 (see schema.sql).
class InMemoryStore implements MemoryStore, OwnerScopedMemoryStore {
  InMemoryStore({this.vectorIndex, this.embedder});

  final VectorIndex? vectorIndex;
  final Future<List<double>> Function(String text)? embedder;

  final List<Message> messages = [];
  final Map<String, Fact> facts = {};
  final _uuid = const Uuid();

  /// Optional post-turn hook used by AgentLoop.
  Future<void> Function(Session session)? afterTurnHook;

  @override
  Future<void> addMessage(Message m) async {
    messages.add(m);
  }

  @override
  Future<void> upsertFact(Fact f) async {
    // Dedup by high textual overlap (simple).
    for (final existing in facts.values) {
      if (existing.ownerKey == f.ownerKey && _jaccard(existing.text, f.text) > 0.85) {
        facts[existing.id] = Fact(
          id: existing.id,
          text: f.text,
          kind: f.kind,
          importance: f.importance > existing.importance
              ? f.importance
              : existing.importance,
          sourceSession: f.sourceSession ?? existing.sourceSession,
          ownerKey: f.ownerKey ?? existing.ownerKey,
          createdAt: existing.createdAt ?? f.createdAt ?? DateTime.now().toUtc(),
          provenance: _mergeProvenance(existing.provenance, f.provenance),
          confidence: f.confidence < existing.confidence
              ? f.confidence
              : existing.confidence,
          ttlDays: f.ttlDays ?? existing.ttlDays,
          state: existing.state == 'active' && f.state == 'active'
              ? 'active'
              : 'pending',
        );
        if (vectorIndex != null && embedder != null) {
          final v = await embedder!(f.text);
          if (v.isNotEmpty) {
            await vectorIndex!.upsert(existing.id, v, {'text': f.text, 'owner_key': f.ownerKey});
          }
        }
        return;
      }
    }
    final id = f.id.isEmpty ? _uuid.v4() : f.id;
    final fact = Fact(
      id: id,
      text: f.text,
      kind: f.kind,
      importance: f.importance,
      sourceSession: f.sourceSession,
      ownerKey: f.ownerKey,
      createdAt: f.createdAt ?? DateTime.now().toUtc(),
      provenance: f.provenance,
      confidence: f.confidence,
      ttlDays: f.ttlDays,
      state: f.state,
    );
    // Policy: max 300 chars, no obvious secrets.
    if (fact.text.length > 300) return;
    if (_looksSecret(fact.text)) return;

    facts[id] = fact;
    if (vectorIndex != null && embedder != null) {
      final v = await embedder!(fact.text);
      if (v.isNotEmpty) await vectorIndex!.upsert(id, v, {'text': fact.text, 'owner_key': fact.ownerKey});
    }
  }

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async =>
      _search(query, k: k);

  @override
  Future<List<MemoryHit>> searchForOwner(String query, {required String ownerKey, int k = 8}) async {
    if (ownerKey.trim().isEmpty) return const [];
    return _search(query, k: k, ownerKey: ownerKey);
  }

  Future<List<MemoryHit>> _search(String query, {required int k, String? ownerKey}) async {
    final now = DateTime.now().toUtc();
    final qTokens = _tokens(query);
    final textHits = <MemoryHit>[];

    for (final f in facts.values) {
      if ((ownerKey != null && f.ownerKey != ownerKey) || f.isExpiredAt(now)) continue;
      final score =
          _bm25ish(qTokens, _tokens(f.text)) * (0.5 + 0.5 * f.importance);
      if (score > 0) {
        textHits.add(_hit(f, score));
      }
    }
    textHits.sort((a, b) => b.score.compareTo(a.score));

    // Hybrid: merge with vector if available (simple RRF).
    if (vectorIndex != null && embedder != null && query.trim().isNotEmpty) {
      final emb = await embedder!(query);
      if (emb.isNotEmpty) {
        final vHits = await vectorIndex!.topK(emb, k);
        final scopedVectorHits = vHits.where((v) {
          final fact = facts[v.id];
          return fact != null &&
              (ownerKey == null || fact.ownerKey == ownerKey) &&
              !fact.isExpiredAt(now);
        }).toList();
        return _rrf([
          textHits.take(20).toList(),
          scopedVectorHits
              .map(
                (v) => MemoryHit(
                  id: v.id,
                  text:
                      (v.meta['text'] as String?) ?? facts[v.id]?.text ?? v.id,
                  score: v.score,
                  provenance: facts[v.id]?.provenance ?? Provenance.unknown,
                  confidence: facts[v.id]?.confidence ?? 0.5,
                  state: facts[v.id]?.state ?? 'pending',
                  ttlDays: facts[v.id]?.ttlDays,
                  ownerKey: facts[v.id]?.ownerKey,
                  createdAt: facts[v.id]?.createdAt,
                ),
              )
              .toList(),
        ], top: k);
      }
    }

    return textHits.take(k).toList();
  }

  @override
  Future<void> afterTurn(Session session) async {
    await afterTurnHook?.call(session);
  }

  Future<List<Fact>> listFacts() async => facts.values.toList();

  Future<void> deleteFact(String id) async {
    facts.remove(id);
  }

  List<MemoryHit> _rrf(
    List<List<MemoryHit>> rankings, {
    int k = 60,
    int top = 8,
  }) {
    final score = <String, double>{};
    final byId = <String, MemoryHit>{};
    for (final r in rankings) {
      for (var i = 0; i < r.length; i++) {
        final id = r[i].id;
        byId[id] = r[i];
        score.update(
          id,
          (s) => s + 1 / (k + i + 1),
          ifAbsent: () => 1 / (k + i + 1),
        );
      }
    }
    final ids = score.keys.toList()
      ..sort((a, b) => score[b]!.compareTo(score[a]!));
    return ids
        .take(top)
        .map((id) => MemoryHit(
              id: id,
              text: byId[id]!.text,
              score: score[id]!,
              provenance: byId[id]!.provenance,
              confidence: byId[id]!.confidence,
              state: byId[id]!.state,
              ttlDays: byId[id]!.ttlDays,
              ownerKey: byId[id]!.ownerKey,
              createdAt: byId[id]!.createdAt,
            ))
        .toList();
  }


  MemoryHit _hit(Fact fact, double score) => MemoryHit(
        id: fact.id,
        text: fact.text,
        score: score,
        provenance: fact.provenance,
        confidence: fact.confidence,
        state: fact.state,
        ttlDays: fact.ttlDays,
        ownerKey: fact.ownerKey,
        createdAt: fact.createdAt,
      );

  Provenance _mergeProvenance(Provenance a, Provenance b) {
    // A deduplicated fact must never become more trusted merely because a
    // later source is trusted. Preserve the less-trusted origin.
    if (a == Provenance.unknown &&
        (b == Provenance.user || b == Provenance.trustedConfig)) {
      return b;
    }
    if (a == Provenance.unknown || b == Provenance.unknown) {
      return Provenance.unknown;
    }
    if (a == Provenance.web || b == Provenance.web) return Provenance.web;
    if (a == Provenance.email || b == Provenance.email) return Provenance.email;
    if (a == Provenance.mcp || b == Provenance.mcp) return Provenance.mcp;
    if (a == Provenance.localFile || b == Provenance.localFile) {
      return Provenance.localFile;
    }
    if (a == Provenance.agent || b == Provenance.agent) return Provenance.agent;
    if (a == Provenance.memory || b == Provenance.memory) return Provenance.memory;
    return a;
  }

  Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]', unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1)
      .toSet();

  double _bm25ish(Set<String> q, Set<String> doc) {
    if (q.isEmpty || doc.isEmpty) return 0;
    final overlap = q.intersection(doc).length;
    return overlap / q.length;
  }

  double _jaccard(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty && tb.isEmpty) return 1;
    final inter = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    return union == 0 ? 0 : inter / union;
  }

  bool _looksSecret(String text) {
    final patterns = [
      RegExp(r'sk-[a-zA-Z0-9]{20,}'),
      RegExp(r'api[_-]?key\s*[:=]', caseSensitive: false),
      RegExp(r'password\s*[:=]', caseSensitive: false),
      RegExp(r'\b\d{13,19}\b'), // crude card number
    ];
    return patterns.any((p) => p.hasMatch(text));
  }
}
