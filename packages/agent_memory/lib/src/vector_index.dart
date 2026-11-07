import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';

/// Brute-force cosine VectorIndex (DEC-05, TASK-04-03).
/// Suitable for ≤ ~50k vectors on typical devices.
class BruteForceVectorIndex implements VectorIndex {
  final Map<String, _Entry> _data = {};

  int get length => _data.length;

  @override
  Future<void> upsert(
    String id,
    List<double> v,
    Map<String, Object?> meta,
  ) async {
    _data[id] = _Entry(normalize(v), Map<String, Object?>.from(meta));
  }

  @override
  Future<List<VectorHit>> topK(List<double> q, int k) async {
    if (_data.isEmpty || k <= 0) return [];
    final qn = normalize(q);
    final scored = <VectorHit>[];
    for (final e in _data.entries) {
      final score = dot(qn, e.value.vector);
      scored.add(VectorHit(id: e.key, score: score, meta: e.value.meta));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(k).toList();
  }

  Future<void> remove(String id) async => _data.remove(id);

  Future<void> clear() async => _data.clear();

  static List<double> normalize(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    if (sum <= 0) return List<double>.from(v);
    final inv = 1.0 / math.sqrt(sum);
    return v.map((x) => x * inv).toList();
  }

  static double dot(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}

class _Entry {
  _Entry(this.vector, this.meta);
  final List<double> vector;
  final Map<String, Object?> meta;
}
