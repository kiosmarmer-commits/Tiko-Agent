import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

import 'community_test.dart' as fixture;

void main() {
  test('isolate layout matches direct simulation byte for byte', () async {
    final a = fixture.twoCliques();
    final b = fixture.twoCliques();

    final direct = ForceLayout.simulate(a);
    final viaIsolate = await IsolateLayout.simulate(b);

    expect(viaIsolate.iterations, direct.iterations);
    expect(viaIsolate.slept, direct.slept);
    for (var i = 0; i < a.nodeCount; i++) {
      expect(b.positionsX[i], a.positionsX[i]);
      expect(b.positionsY[i], a.positionsY[i]);
    }
  });

  test('isolate layout supports warm start from existing positions', () async {
    final graph = fixture.twoCliques();
    ForceLayout.simulate(graph);
    final beforeX = Float32List.fromList(graph.positionsX);
    final beforeY = Float32List.fromList(graph.positionsY);

    final result = await IsolateLayout.simulate(graph, warmStart: true);

    expect(result.slept, isTrue);
    var moved = false;
    for (var i = 0; i < graph.nodeCount; i++) {
      if (graph.positionsX[i] != beforeX[i] ||
          graph.positionsY[i] != beforeY[i]) {
        moved = true;
        break;
      }
    }
    expect(moved, isTrue);
  });

  test('isolate layout handles empty graphs', () async {
    final empty = GraphCsr.fromEdges(0, const []);
    final result = await IsolateLayout.simulate(empty);
    expect(result.iterations, 0);
    expect(result.slept, isTrue);
  });
}
