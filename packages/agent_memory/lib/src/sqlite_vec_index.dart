import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// Vector index backed by embeddings table; tries sqlite-vec extension.
class SqliteVecIndex implements VectorIndex {
  SqliteVecIndex(this.db, {this.extensionPath});

  final Database db;
  final String? extensionPath;
  bool vecLoaded = false;

  /// Attempt load sqlite-vec; returns true if virtual table usable.
  bool tryLoadExtension() {
    final path =
        extensionPath ??
        const String.fromEnvironment('SQLITE_VEC_PATH', defaultValue: '');
    if (path.isEmpty) return false;
    // sqlite3 2.x does not expose SQLite's dynamic extension loader through
    // Database. Keep the extension optional and use the portable fallback.
    // This also prevents startup failure when sqlite-vec is not installed.
    vecLoaded = false;
    return false;
  }

  @override
  Future<void> upsert(
    String id,
    List<double> vector,
    Map<String, Object?> meta,
  ) async {
    final blob = Float32List.fromList(vector).buffer.asUint8List();
    db.execute(
      'INSERT OR REPLACE INTO embeddings (id, dim, vector, meta_json) VALUES (?,?,?,?)',
      [id, vector.length, blob, jsonEncode(meta)],
    );
    if (vecLoaded) {
      try {
        final lit = vector.map((e) => e.toString()).join(',');
        db.execute(
          'INSERT OR REPLACE INTO vec_facts(id, embedding) VALUES (?, ?)',
          [id, '[$lit]'],
        );
      } catch (_) {}
    }
  }

  @override
  Future<List<VectorHit>> topK(List<double> query, int k) async {
    if (vecLoaded) {
      try {
        final lit = query.map((e) => e.toString()).join(',');
        final rows = db.select(
          'SELECT id, distance FROM vec_facts WHERE embedding MATCH ? AND k = ?',
          ['[$lit]', k],
        );
        return rows
            .map(
              (r) => VectorHit(
                id: r['id'] as String,
                score:
                    1.0 / (1.0 + ((r['distance'] as num?)?.toDouble() ?? 1.0)),
                meta: const {},
              ),
            )
            .toList();
      } catch (_) {}
    }
    // brute-force from embeddings table
    final rows = db.select('SELECT id, dim, vector, meta_json FROM embeddings');
    final hits = <VectorHit>[];
    for (final r in rows) {
      final blob = r['vector'] as Uint8List;
      final dim = r['dim'] as int;
      final vec = Float32List.view(blob.buffer, blob.offsetInBytes, dim);
      final score = _cosine(query, vec);
      Map<String, Object?> meta = {};
      try {
        meta = Map<String, Object?>.from(
          jsonDecode(r['meta_json'] as String? ?? '{}') as Map,
        );
      } catch (_) {}
      hits.add(VectorHit(id: r['id'] as String, score: score, meta: meta));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(k).toList();
  }

  double _cosine(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    if (n == 0) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final d = (na * nb);
    if (d <= 0) return 0;
    return dot / (math.sqrt(d));
  }

  /// Removes one embedding row; mirrors [BruteForceVectorIndex.remove] so
  /// hosts can swap indexes without special-casing removal.
  Future<void> remove(String id) async {
    db.execute('DELETE FROM embeddings WHERE id = ?', [id]);
  }

  /// Number of durable embeddings backing this index.
  int get length =>
      db.select('SELECT COUNT(*) AS c FROM embeddings').first['c'] as int;
}
