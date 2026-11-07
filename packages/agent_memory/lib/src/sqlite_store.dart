import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:uuid/uuid.dart';

import 'drift_schema.dart';

/// SQLite + FTS5 MemoryStore (AGD-04). Falls back if native lib missing.
///
/// Retrieval fuses FTS5 BM25 and vector cosine rankings with Reciprocal Rank
/// Fusion (FR-10 / ALG-03), matching the fusion already used by
/// [InMemoryStore] and [PersistentMemoryStore].
class SqliteMemoryStore implements MemoryStore, OwnerScopedMemoryStore {
  SqliteMemoryStore._(this.db, {this.vectorIndex, this.embedder});

  final Database db;
  final VectorIndex? vectorIndex;
  final Future<List<double>> Function(String text)? embedder;
  final _uuid = const Uuid();

  /// RRF smoothing constant (FR-10): standard value 60.
  static const int rrfK = 60;

  static Future<SqliteMemoryStore?> tryOpen(
    String dbPath, {
    VectorIndex? vectorIndex,
    Future<List<double>> Function(String text)? embedder,
  }) async {
    try {
      await File(dbPath).parent.create(recursive: true);
      final db = sqlite3.open(dbPath);
      final store = SqliteMemoryStore._(
        db,
        vectorIndex: vectorIndex,
        embedder: embedder,
      );
      store._migrate();
      return store;
    } catch (e) {
      stderr.writeln(
        'SqliteMemoryStore unavailable: $e — use PersistentMemoryStore',
      );
      return null;
    }
  }

  void _migrate() {
    DriftStyleMigrations.migrate(db);
  }

  @override
  Future<void> addMessage(Message m) async {
    final id = _uuid.v4();
    db.execute(
      'INSERT INTO messages (id, session_id, role, content, tool_name, created_at) VALUES (?,?,?,?,?,?)',
      [
        id,
        m.sessionId,
        m.role,
        m.content,
        m.toolName,
        m.createdAt.toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<void> upsertFact(Fact f) async {
    if (f.text.length > 300) return;
    if (_looksSecret(f.text)) return;

    // dedup by simple equality
    final existing = db.select(
      'SELECT id, text, importance, provenance, confidence, ttl_days, state, owner_key, created_at FROM facts WHERE text = ? AND owner_key IS ? LIMIT 1',
      [f.text, f.ownerKey],
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as String;
      final imp = (existing.first['importance'] as num).toDouble();
      final newImp = f.importance > imp ? f.importance : imp;
      db.execute(
        'UPDATE facts SET importance = ?, provenance = ?, confidence = ?, ttl_days = ?, state = ?, owner_key = ? WHERE id = ?',
        [
          newImp,
          _mergeProvenance(
            Fact.provenanceFromName(existing.first['provenance']),
            f.provenance,
          ).name,
          f.confidence < ((existing.first['confidence'] as num?)?.toDouble() ?? 0.7)
              ? f.confidence
              : ((existing.first['confidence'] as num?)?.toDouble() ?? 0.7),
          f.ttlDays ?? existing.first['ttl_days'],
          f.state == 'active' && existing.first['state'] == 'active'
              ? 'active'
              : 'pending',
          f.ownerKey,
          id,
        ],
      );
      return;
    }

    final id = f.id.isEmpty ? _uuid.v4() : f.id;
    db.execute(
      'INSERT INTO facts (id, text, kind, importance, source_session, created_at, provenance, confidence, ttl_days, state, owner_key) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        f.text,
        f.kind,
        f.importance,
        f.sourceSession,
        (f.createdAt ?? DateTime.now().toUtc()).toIso8601String(),
        f.provenance.name,
        f.confidence,
        f.ttlDays,
        f.state,
        f.ownerKey,
      ],
    );
    try {
      db.execute(
        'INSERT INTO facts_fts(rowid, text) SELECT rowid, text FROM facts WHERE id = ?',
        [id],
      );
    } catch (_) {}

    if (vectorIndex != null && embedder != null) {
      final v = await embedder!(f.text);
      if (v.isNotEmpty) await vectorIndex!.upsert(id, v, {'text': f.text, 'owner_key': f.ownerKey});
    }
  }

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) =>
      _search(query, k: k);

  @override
  Future<List<MemoryHit>> searchForOwner(
    String query, {required String ownerKey, int k = 8}) {
    if (ownerKey.trim().isEmpty) return Future.value(const []);
    return _search(query, k: k, ownerKey: ownerKey);
  }

  Future<List<MemoryHit>> _search(String query, {required int k, String? ownerKey}) async {
    final now = DateTime.now().toUtc();

    // Ranked list #1 — FTS5 BM25 (rank 1 = best; lower bm25 is better).
    final ftsRanked = <MemoryHit>[];
    try {
      final rows = db.select(
        '''
        SELECT f.id, f.text, f.importance, f.provenance,
               f.confidence, f.ttl_days, f.state, f.owner_key, f.created_at,
               bm25(facts_fts) AS rank
        FROM facts_fts
        JOIN facts f ON f.rowid = facts_fts.rowid
        WHERE facts_fts MATCH ?
          AND (? IS NULL OR f.owner_key = ?)
          AND (f.ttl_days IS NULL OR datetime(f.created_at, '+' || f.ttl_days || ' days') > datetime('now'))
        ORDER BY rank
        LIMIT ?
        ''',
        [query, ownerKey, ownerKey, k],
      );
      for (final r in rows) {
        final imp = (r['importance'] as num?)?.toDouble() ?? 0.5;
        final rank = (r['rank'] as num?)?.toDouble() ?? 0;
        // bm25: lower is better → invert
        ftsRanked.add(
          MemoryHit(
            id: r['id'] as String,
            text: r['text'] as String,
            score: (1.0 / (1.0 + rank.abs())) * (0.5 + 0.5 * imp),
            provenance: Fact.provenanceFromName(r['provenance']),
            confidence: (r['confidence'] as num?)?.toDouble() ?? 0.7,
            state: r['state'] as String? ?? 'active',
            ttlDays: r['ttl_days'] as int?,
            ownerKey: r['owner_key'] as String?,
            createdAt: DateTime.tryParse(r['created_at'] as String? ?? '')?.toUtc(),
          ),
        );
      }
    } catch (_) {
      // LIKE fallback (FTS5 may be unavailable on a minimal SQLite build).
      final rows = db.select(
        '''SELECT id, text, importance, provenance, confidence, ttl_days, state, owner_key, created_at
           FROM facts WHERE text LIKE ? AND (? IS NULL OR owner_key = ?)
           AND (ttl_days IS NULL OR datetime(created_at, '+' || ttl_days || ' days') > datetime('now'))
           LIMIT ?''',
        ['%$query%', ownerKey, ownerKey, k],
      );
      for (final r in rows) {
        ftsRanked.add(
          MemoryHit(
            id: r['id'] as String,
            text: r['text'] as String,
            score: 0.5 * ((r['importance'] as num?)?.toDouble() ?? 0.5),
            provenance: Fact.provenanceFromName(r['provenance']),
            confidence: (r['confidence'] as num?)?.toDouble() ?? 0.7,
            state: r['state'] as String? ?? 'active',
            ttlDays: r['ttl_days'] as int?,
            ownerKey: r['owner_key'] as String?,
            createdAt: DateTime.tryParse(r['created_at'] as String? ?? '')?.toUtc(),
          ),
        );
      }
    }

    // Ranked list #2 — vector cosine similarity (rank 1 = best).
    final vecRanked = <MemoryHit>[];
    if (vectorIndex != null && embedder != null && query.trim().isNotEmpty) {
      try {
        final emb = await embedder!(query);
        if (emb.isNotEmpty) {
          final vHits = await vectorIndex!.topK(emb, k);
          for (final v in vHits) {
            if (vecRanked.any((h) => h.id == v.id)) continue;
            final factRows = db.select(
              'SELECT owner_key, created_at, ttl_days FROM facts WHERE id = ? LIMIT 1',
              [v.id],
            );
            if (factRows.isEmpty) continue;
            final owner = factRows.first['owner_key'] as String?;
            if (ownerKey != null && owner != ownerKey) continue;
            final createdAt = DateTime.tryParse(factRows.first['created_at'] as String? ?? '')?.toUtc();
            final ttl = factRows.first['ttl_days'] as int?;
            if (ttl != null && createdAt != null &&
                !createdAt.add(Duration(days: ttl)).isAfter(now)) continue;
            vecRanked.add(
              MemoryHit(
                id: v.id,
                text: (v.meta['text'] as String?) ?? factsText(v.id),
                score: v.score,
                provenance: _factProvenance(v.id),
                confidence: _factConfidence(v.id),
                state: _factState(v.id),
                ttlDays: ttl,
                ownerKey: owner,
                createdAt: createdAt,
              ),
            );
          }
        }
      } catch (_) {
        // Vector retrieval is best-effort: embedding or index failure must
        // not take the text search down with it.
      }
    }

    // FR-10 / ALG-03 — Reciprocal Rank Fusion of both rankings.
    // RRF(d) = Σ_m 1 / (rrfK + r_m(d)) with 1-based rank r_m. Ranks from two
    // incomparable scoring systems (BM25 distance vs cosine similarity) are
    // never mixed as raw scores; they fuse only through this rank formula.
    if (ftsRanked.isEmpty && vecRanked.isEmpty) return const [];
    if (vecRanked.isEmpty) return ftsRanked.take(k).toList();
    if (ftsRanked.isEmpty) return vecRanked.take(k).toList();
    return _rrf([ftsRanked, vecRanked], top: k);
  }

  /// Reciprocal Rank Fusion — same formula as [InMemoryStore] and
  /// [PersistentMemoryStore]: score(d) = Σ 1 / (k + rank), rank 1-based.
  List<MemoryHit> _rrf(
    List<List<MemoryHit>> rankings, {
    int k = rrfK,
    int top = 8,
  }) {
    final score = <String, double>{};
    final byId = <String, MemoryHit>{};
    for (final r in rankings) {
      for (var i = 0; i < r.length; i++) {
        final id = r[i].id;
        byId.putIfAbsent(id, () => r[i]);
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
        .map(
          (id) => MemoryHit(
            id: id,
            text: byId[id]!.text,
            score: score[id]!,
            provenance: byId[id]!.provenance,
            confidence: byId[id]!.confidence,
            state: byId[id]!.state,
            ttlDays: byId[id]!.ttlDays,
            ownerKey: byId[id]!.ownerKey,
            createdAt: byId[id]!.createdAt,
          ),
        )
        .toList();
  }

  @override
  Future<void> afterTurn(Session session) async {
    // Explicit user memory is captured in AgentLoop through the safety wrapper.
  }

  Future<List<Map<String, dynamic>>> listFacts({int limit = 50}) async {
    final rows = db.select(
      '''SELECT id, text, kind, importance, provenance, confidence,
                ttl_days, state, owner_key, created_at
         FROM facts
         WHERE (ttl_days IS NULL OR
                datetime(created_at, '+' || ttl_days || ' days') > datetime('now'))
         ORDER BY importance DESC LIMIT ?''',
      [limit],
    );
    return rows
        .map(
          (r) => {
            'id': r['id'],
            'text': r['text'],
            'kind': r['kind'],
            'importance': r['importance'],
            'provenance': r['provenance'],
            'confidence': r['confidence'],
            'ttl_days': r['ttl_days'],
            'state': r['state'],
            'owner_key': r['owner_key'],
            'created_at': r['created_at'],
          },
        )
        .toList();
  }

  Future<bool> deleteFact(String id) async {
    final rows = db.select(
      'SELECT rowid, text FROM facts WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return false;
    // facts_fts is an external-content table without delete triggers. Remove
    // its index row explicitly before deleting the source row.
    try {
      db.execute(
        "INSERT INTO facts_fts(facts_fts, rowid, text) VALUES('delete', ?, ?)",
        [rows.first['rowid'], rows.first['text']],
      );
    } catch (_) {
      // FTS5 may be unavailable on a minimal SQLite build; the facts row is
      // still authoritative and will no longer be returned by safe retrieval.
    }
    db.execute('DELETE FROM facts WHERE id = ?', [id]);
    return true;
  }


  String factsText(String id) {
    final rows = db.select('SELECT text FROM facts WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? id : (rows.first['text'] as String? ?? id);
  }

  Provenance _factProvenance(String id) {
    final rows = db.select('SELECT provenance FROM facts WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? Provenance.unknown : Fact.provenanceFromName(rows.first['provenance']);
  }

  double _factConfidence(String id) {
    final rows = db.select('SELECT confidence FROM facts WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? 0.5 : (rows.first['confidence'] as num?)?.toDouble() ?? 0.5;
  }

  String _factState(String id) {
    final rows = db.select('SELECT state FROM facts WHERE id = ? LIMIT 1', [id]);
    return rows.isEmpty ? 'pending' : (rows.first['state'] as String? ?? 'pending');
  }

  Provenance _mergeProvenance(Provenance a, Provenance b) {
    // An explicit new user confirmation may rehabilitate a legacy record
    // whose origin was not captured. Unknown data must never be upgraded by
    // an agent, web page, MCP server, or other imported source.
    if (a == Provenance.unknown &&
        (b == Provenance.user || b == Provenance.trustedConfig)) return b;
    if (a == Provenance.unknown || b == Provenance.unknown) return Provenance.unknown;
    const order = <Provenance>[
      Provenance.web, Provenance.email, Provenance.mcp, Provenance.localFile,
      Provenance.agent, Provenance.memory, Provenance.user, Provenance.trustedConfig,
    ];
    for (final candidate in order) {
      if (a == candidate || b == candidate) return candidate;
    }
    return Provenance.unknown;
  }

  void close() => db.dispose();

  bool _looksSecret(String t) {
    final lower = t.toLowerCase();
    return lower.contains('api_key') ||
        lower.contains('password') ||
        lower.contains('secret') ||
        RegExp(r'sk-[a-zA-Z0-9]{20,}').hasMatch(t);
  }
}
