import 'dart:math' as math;
import 'dart:typed_data';

/// Deterministic IVF-flat index (AI-31, ADR-06): k-means partitioning of
/// L2-normalized vectors with exact re-ranking inside the probed clusters.
/// Fixed seeding (evenly spaced input vectors) and a fixed iteration count
/// make the partition reproducible — no RNG anywhere.
///
/// Purpose: measure whether ANN beats brute-force search WITHOUT missing the
/// target (AI-31). The default retrieval path stays brute-force until this
/// evaluation shows a real win (ADR-06).
class IvfFlatIndex {
  IvfFlatIndex._(this.dim, this.centroids, this.members);

  final int dim;
  final List<Float32List> centroids;

  /// Cluster id -> vector indices, ascending.
  final List<List<int>> members;

  static IvfFlatIndex build(
    List<Float32List> vectors, {
    int clusters = 16,
    int iterations = 10,
  }) {
    if (vectors.isEmpty) {
      return IvfFlatIndex._(0, [], []);
    }
    final dim = vectors.first.length;
    final n = math.min(clusters, vectors.length);
    final centroids = [
      for (var c = 0; c < n; c++)
        Float32List.fromList(vectors[(c * vectors.length) ~/ n].toList()),
    ];
    final assignment = List<int>.filled(vectors.length, 0);
    for (var it = 0; it < iterations; it++) {
      for (var i = 0; i < vectors.length; i++) {
        assignment[i] = _nearest(centroids, vectors[i]);
      }
      final sums = List.generate(n, (_) => Float32List(dim));
      final counts = List<int>.filled(n, 0);
      for (var i = 0; i < vectors.length; i++) {
        final c = assignment[i];
        counts[c]++;
        final vector = vectors[i];
        final sum = sums[c];
        for (var d = 0; d < dim; d++) {
          sum[d] += vector[d];
        }
      }
      for (var c = 0; c < n; c++) {
        if (counts[c] == 0) continue;
        final centroid = centroids[c];
        final sum = sums[c];
        var norm = 0.0;
        for (var d = 0; d < dim; d++) {
          centroid[d] = sum[d] / counts[c];
          norm += centroid[d] * centroid[d];
        }
        norm = math.sqrt(norm);
        if (norm > 0) {
          for (var d = 0; d < dim; d++) {
            centroid[d] /= norm;
          }
        }
      }
    }
    final members = List.generate(n, (_) => <int>[]);
    for (var i = 0; i < vectors.length; i++) {
      members[assignment[i]].add(i);
    }
    return IvfFlatIndex._(dim, centroids, members);
  }

  static int _nearest(List<Float32List> centroids, Float32List vector) {
    var best = 0;
    var bestDot = -double.infinity;
    for (var c = 0; c < centroids.length; c++) {
      var dot = 0.0;
      final centroid = centroids[c];
      for (var d = 0; d < vector.length; d++) {
        dot += centroid[d] * vector[d];
      }
      if (dot > bestDot) {
        bestDot = dot;
        best = c;
      }
    }
    return best;
  }

  /// Exact re-ranked search inside the [nprobe] most similar clusters.
  /// Returns (vectorIndex, score) pairs sorted by score desc, ties by index.
  List<(int, double)> search(
    Float32List query, {
    List<Float32List> vectors = const [],
    int nprobe = 1,
    int limit = 10,
  }) {
    if (centroids.isEmpty || vectors.isEmpty) return const [];
    final order = List<int>.generate(centroids.length, (c) => c)
      ..sort((a, b) {
        final cmp = _dot(centroids[b], query).compareTo(_dot(centroids[a], query));
        return cmp != 0 ? cmp : a.compareTo(b);
      });
    final probe = math.min(nprobe, order.length);
    final scored = <(int, double)>[];
    for (var p = 0; p < probe; p++) {
      for (final i in members[order[p]]) {
        scored.add((i, _dot(vectors[i], query)));
      }
    }
    scored.sort((a, b) {
      final cmp = b.$2.compareTo(a.$2);
      return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
    });
    return scored.take(limit).toList();
  }

  static double _dot(Float32List a, Float32List b) {
    var sum = 0.0;
    for (var d = 0; d < math.min(a.length, b.length); d++) {
      sum += a[d] * b[d];
    }
    return sum;
  }
}
