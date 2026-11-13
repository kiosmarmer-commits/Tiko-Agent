import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote note(String path, List<String> targets) => IndexedNote(
      path: path,
      title: path,
      mtimeNs: 0,
      sizeBytes: 0,
      contentHash: 'hash-$path',
      wordCount: 1,
      props: const {},
      tags: const [],
      aliases: const [],
      links: [
        for (final t in targets)
          ParsedLink(
            target: t,
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: false,
            offset: 0,
          ),
      ],
      chunks: const [],
    );

GraphCsr chain(int count) => GraphCsr.build([
      for (var i = 0; i < count; i++)
        note('n$i.md', i + 1 < count ? ['n${i + 1}'] : []),
    ]);

void main() {
  test('layout is deterministic', () {
    final a = chain(30);
    final b = chain(30);
    ForceLayout.simulate(a, config: const ForceLayoutConfig(maxIterations: 60));
    ForceLayout.simulate(b, config: const ForceLayoutConfig(maxIterations: 60));
    for (var i = 0; i < 30; i++) {
      expect(a.positionsX[i], b.positionsX[i]);
      expect(a.positionsY[i], b.positionsY[i]);
    }
  });

  test('edges settle near the spring length while the graph spreads out', () {
    final graph = chain(40);
    ForceLayout.simulate(graph, config: const ForceLayoutConfig(maxIterations: 300));

    var maxEdgeSq = 0.0;
    for (var src = 0; src < graph.nodeCount - 1; src++) {
      final dx = graph.positionsX[src] - graph.positionsX[src + 1];
      final dy = graph.positionsY[src] - graph.positionsY[src + 1];
      final d2 = (dx * dx + dy * dy).toDouble();
      if (d2 > maxEdgeSq) maxEdgeSq = d2;
    }
    expect(maxEdgeSq, lessThan(300 * 300));

    var minX = graph.positionsX.reduce((a, b) => a < b ? a : b);
    var maxX = graph.positionsX.reduce((a, b) => a > b ? a : b);
    var minY = graph.positionsY.reduce((a, b) => a < b ? a : b);
    var maxY = graph.positionsY.reduce((a, b) => a > b ? a : b);
    final spread = (maxX - minX) + (maxY - minY);
    expect(spread, greaterThan(300));
  });

  test('sleeps before max iterations on a stable graph', () {
    final graph = chain(25);
    final result = ForceLayout.simulate(
      graph,
      config: const ForceLayoutConfig(maxIterations: 500),
    );
    expect(result.slept, isTrue);
    expect(result.iterations, lessThan(500));
    expect(result.finalEnergy, lessThan(1e-3));
  });

  test('warm start preserves existing positions when nothing moves', () {
    final graph = chain(5);
    for (var i = 0; i < 5; i++) {
      graph.positionsX[i] = i * 100;
      graph.positionsY[i] = i * 100;
    }
    final result = ForceLayout.simulate(
      graph,
      config: const ForceLayoutConfig(
        maxIterations: 0,
        repulsion: 0,
        springStrength: 0,
        centerPull: 0,
      ),
      warmStart: true,
    );
    expect(result.iterations, 1);
    expect(graph.positionsX[3], 300);
    expect(graph.positionsY[3], 300);
  });

  test('handles single node and empty graph', () {
    final single = chain(1);
    ForceLayout.simulate(single);
    expect(single.positionsX[0].isFinite, isTrue);

    final empty = GraphCsr.build([]);
    final result = ForceLayout.simulate(empty);
    expect(result.slept, isTrue);
  });
}
