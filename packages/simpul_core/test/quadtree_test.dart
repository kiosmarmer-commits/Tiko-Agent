import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  test('queryRegion matches brute force scan', () {
    final n = 200;
    final x = Float32List(n);
    final y = Float32List(n);
    for (var i = 0; i < n; i++) {
      x[i] = (i * 37 % 100).toDouble();
      y[i] = (i * 53 % 100).toDouble();
    }
    final tree = QuadtreeIndex.build(x, y);

    const minX = 20.0, minY = 30.0, maxX = 60.0, maxY = 70.0;
    final got = tree.queryRegion(minX, minY, maxX, maxY);
    final expected = <int>[
      for (var i = 0; i < n; i++)
        if (x[i] >= minX && x[i] <= maxX && y[i] >= minY && y[i] <= maxY) i,
    ];
    expect(got, expected);
  });

  test('queryRegion with duplicates and empty tree', () {
    final dupX = Float32List(3);
    final dupY = Float32List(3);
    final dupTree = QuadtreeIndex.build(dupX, dupY);
    expect(dupTree.queryRegion(-1, -1, 1, 1), [0, 1, 2]);

    final empty = QuadtreeIndex.build(Float32List(0), Float32List(0));
    expect(empty.queryRegion(-100, -100, 100, 100), isEmpty);
    expect(empty.hitTest(0, 0), isNull);
  });

  test('hitTest finds the nearest node and respects the radius', () {
    final x = Float32List.fromList([0, 50, 100]);
    final y = Float32List.fromList([0, 0, 0]);
    final tree = QuadtreeIndex.build(x, y);

    expect(tree.hitTest(1, 1, radius: 10), 0);
    expect(tree.hitTest(48, 0, radius: 10), 1);
    expect(tree.hitTest(60, 0, radius: 9), isNull);
    expect(tree.hitTest(60, 0, radius: 10), 1);
    expect(tree.hitTest(60, 0, radius: 15), 1);
  });

  test('hitTest ties resolve to the smallest node id', () {
    final x = Float32List.fromList([10, -10]);
    final y = Float32List.fromList([0, 0]);
    final tree = QuadtreeIndex.build(x, y);
    expect(tree.hitTest(0, 0, radius: 20), 0);
  });
}
