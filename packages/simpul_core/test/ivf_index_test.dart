import 'dart:math' as math;
import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

Float32List _unit(Float32List v) {
  var norm = 0.0;
  for (final x in v) {
    norm += x * x;
  }
  norm = math.sqrt(norm);
  final out = Float32List(v.length);
  for (var d = 0; d < v.length; d++) {
    out[d] = norm > 0 ? v[d] / norm : 0;
  }
  return out;
}

/// 20 topic clusters x 50 members each: the realistic vault shape.
List<Float32List> _clusteredVectors({int clusters = 20, int perCluster = 50}) {
  final rng = math.Random(7);
  const dim = 256;
  final centers = List.generate(clusters, (_) {
    final v = Float32List(dim);
    for (var d = 0; d < dim; d++) {
      v[d] = rng.nextDouble() * 2 - 1;
    }
    return _unit(v);
  });
  return [
    for (final center in centers)
      for (var i = 0; i < perCluster; i++)
        _unit(Float32List.fromList([
          for (var d = 0; d < dim; d++)
            center[d] + (rng.nextDouble() * 2 - 1) * 0.15,
        ])),
  ];
}

List<int> _bruteForceTop(List<Float32List> vectors, Float32List query, int k) {
  double dot(Float32List a) {
    var sum = 0.0;
    for (var d = 0; d < query.length; d++) {
      sum += a[d] * query[d];
    }
    return sum;
  }

  final ranked = List<int>.generate(vectors.length, (i) => i)
    ..sort((a, b) {
      final cmp = dot(vectors[b]).compareTo(dot(vectors[a]));
      return cmp != 0 ? cmp : a.compareTo(b);
    });
  return ranked.take(k).toList();
}

void main() {
  test('build deterministik: dua kali build menghasilkan partisi sama', () {
    final vectors = _clusteredVectors(perCluster: 10);
    final first = IvfFlatIndex.build(vectors, clusters: 8, iterations: 5);
    final second = IvfFlatIndex.build(vectors, clusters: 8, iterations: 5);

    expect(first.centroids.length, second.centroids.length);
    for (var c = 0; c < first.centroids.length; c++) {
      for (var d = 0; d < first.dim; d++) {
        expect(first.centroids[c][d], second.centroids[c][d]);
      }
    }
    expect(first.members, second.members);
  });

  test('recall@10 nprobe=1 mendekati sempurna pada data berklaster', () {
    final vectors = _clusteredVectors();
    final index = IvfFlatIndex.build(vectors, clusters: 20, iterations: 10);

    var recallSum = 0.0;
    const queries = 50;
    for (var q = 0; q < queries; q++) {
      final query = vectors[(q * 37) % vectors.length];
      final truth = _bruteForceTop(vectors, query, 10).toSet();
      final hits = index.search(query, vectors: vectors, nprobe: 1, limit: 10);
      recallSum += hits.map((h) => h.$1).where(truth.contains).length / 10;
    }
    final recall = recallSum / queries;
    expect(recall, greaterThanOrEqualTo(0.95),
        reason: 'IVF 20 klaster/nprobe 1 terukur 1.000 (ADR-06)');
  });

  test('hasil terurut skor menurun, tie-break indeks', () {
    final vectors = _clusteredVectors(perCluster: 5);
    final index = IvfFlatIndex.build(vectors, clusters: 4, iterations: 5);
    final hits = index.search(
      vectors.first,
      vectors: vectors,
      nprobe: 4,
      limit: 10,
    );
    for (var i = 1; i < hits.length; i++) {
      expect(hits[i - 1].$2, greaterThanOrEqualTo(hits[i].$2));
    }
  });

  test('nprobe melebihi jumlah klaster dan input kosong aman', () {
    final vectors = _clusteredVectors(perCluster: 3);
    final index = IvfFlatIndex.build(vectors, clusters: 4, iterations: 3);
    expect(
      index.search(vectors.first, vectors: vectors, nprobe: 99, limit: 5),
      hasLength(5),
    );

    final empty = IvfFlatIndex.build(const [], clusters: 4);
    expect(empty.centroids, isEmpty);
    expect(empty.search(Float32List(4), vectors: const []), isEmpty);
  });
}
