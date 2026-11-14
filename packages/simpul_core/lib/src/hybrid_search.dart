import 'dart:math' as math;
import 'dart:typed_data';

import 'embedding.dart';
import 'semantic_index.dart';
import 'vault_index.dart';

/// Hybrid lexical + vector search fused with Reciprocal Rank Fusion (AI-20).
class HybridSearcher {
  HybridSearcher({
    required this.index,
    required this.semantic,
    required this.embedder,
    this.rrfK = 60,
  });

  final VaultIndex index;
  final SemanticIndex semantic;
  final EmbeddingProvider embedder;
  final int rrfK;

  Future<List<SearchHit>> search(
    String query, {
    int limit = 20,
    bool useSemantic = true,
    Set<String>? allowedPaths,
  }) async {
    final lexical = await index.search(query, limit: limit);
    if (!useSemantic) return lexical;

    final queryVec = embedder.embed(query);
    final semanticHits = await semantic.search(
      queryVec,
      limit: limit,
      allowedPaths: allowedPaths,
    );

    final byPath = <String, SearchHit>{};
    final scores = <String, double>{};
    void accumulate(List<({String key, SearchHit hit})> ranked) {
      for (var rank = 0; rank < ranked.length; rank++) {
        final entry = ranked[rank];
        scores[entry.key] = (scores[entry.key] ?? 0) + 1 / (rrfK + rank + 1);
        final existing = byPath[entry.key];
        if (existing == null ||
            (existing.snippet.isEmpty && entry.hit.snippet.isNotEmpty)) {
          byPath[entry.key] = entry.hit;
        }
      }
    }

    accumulate([
      for (final hit in lexical) (key: hit.path, hit: hit),
    ]);
    accumulate([
      for (final hit in semanticHits)
        (
          key: hit.notePath,
          hit: SearchHit(
            path: hit.notePath,
            title: hit.notePath,
            score: hit.score,
            snippet: '',
            headingPath: hit.headingPath,
          ),
        ),
    ]);

    final fused = [
      for (final entry in scores.entries)
        (entry.value, byPath[entry.key]!),
    ]..sort((a, b) => b.$1.compareTo(a.$1));

    return [
      for (final (score, hit) in fused.take(limit))
        SearchHit(
          path: hit.path,
          title: hit.title,
          score: score,
          snippet: hit.snippet,
          headingPath: hit.headingPath,
        ),
    ];
  }
}

/// Sanity helper used by tests and the benchmark: exact cosine ranking over
/// full-precision vectors, to measure the recall cost of int8 quantization.
List<int> exactTopK(Float32List query, List<Float32List> vectors, int k) {
  final scored = <(double, int)>[];
  for (var i = 0; i < vectors.length; i++) {
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var j = 0; j < query.length; j++) {
      dot += query[j] * vectors[i][j];
      na += query[j] * query[j];
      nb += vectors[i][j] * vectors[i][j];
    }
    final norm = na > 0 && nb > 0 ? math.sqrt(na) * math.sqrt(nb) : 1.0;
    scored.add((dot / norm, i));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return [
    for (final (_, i) in scored.take(k)) i,
  ];
}
