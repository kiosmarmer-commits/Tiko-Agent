import 'dart:math' as math;

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

GraphCsr syntheticNetwork() {
  final edges = <(int, int)>[];
  for (var c = 0; c < 4; c++) {
    for (var i = 0; i < 12; i++) {
      for (var j = i + 1; j < 12; j++) {
        edges.add((c * 12 + i, c * 12 + j));
      }
    }
    if (c > 0) edges.add((c * 12, (c - 1) * 12));
  }
  final graph = GraphCsr.fromEdges(48, edges);
  for (var i = 0; i < 48; i++) {
    graph.positionsX[i] = i.toDouble();
    graph.positionsY[i] = 0;
  }
  return graph;
}

void main() {
  test('multi-level layout produces finite, spread positions', () {
    final graph = syntheticNetwork();
    final result = MultiLevelLayout.simulate(graph);

    var minX = double.infinity, maxX = double.negativeInfinity;
    var minY = double.infinity, maxY = double.negativeInfinity;
    for (var i = 0; i < graph.nodeCount; i++) {
      final x = graph.positionsX[i];
      final y = graph.positionsY[i];
      expect(x.isFinite, isTrue, reason: 'node $i x not finite');
      expect(y.isFinite, isTrue, reason: 'node $i y not finite');
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
    expect(maxX - minX, greaterThan(50));
    expect(maxY - minY, greaterThan(50));
    expect(result.iterations, greaterThan(0));
  });

  test('multi-level layout is deterministic', () {
    final a = syntheticNetwork();
    final b = syntheticNetwork();
    MultiLevelLayout.simulate(a);
    MultiLevelLayout.simulate(b);
    for (var i = 0; i < a.nodeCount; i++) {
      expect(b.positionsX[i], a.positionsX[i]);
      expect(b.positionsY[i], a.positionsY[i]);
    }
  });

  test('multi-level falls back to direct simulation when no coarsening', () {
    final single = GraphCsr.fromEdges(1, const []);
    final result = MultiLevelLayout.simulate(single);
    expect(result.iterations, greaterThan(0));
    expect(single.positionsX[0].isFinite, isTrue);
  });
}
