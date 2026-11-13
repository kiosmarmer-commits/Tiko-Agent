import 'dart:math' as math;

import 'community.dart';
import 'force_layout.dart';
import 'graph_csr.dart';

/// Multi-level layout acceleration (GRA-L04): coarsen the graph with Louvain
/// communities, lay out the coarse graph, prolongate positions back to every
/// node, then refine with a warm-started simulation. Deterministic end to end
/// because Louvain and the force simulation are deterministic.
abstract final class MultiLevelLayout {
  static LayoutResult simulate(
    GraphCsr graph, {
    ForceLayoutConfig config = const ForceLayoutConfig(),
  }) {
    final n = graph.nodeCount;
    if (n == 0) {
      return const LayoutResult(iterations: 0, finalEnergy: 0, slept: true);
    }

    final comm = CommunityDetector.louvain(graph);
    final coarseCount = comm.communityCount;
    if (coarseCount >= n) {
      return ForceLayout.simulate(graph, config: config);
    }

    final coarseEdgeSet = <(int, int)>{};
    for (var src = 0; src < n; src++) {
      for (var e = graph.offsets[src]; e < graph.offsets[src + 1]; e++) {
        final c1 = comm.communityOf[src];
        final c2 = comm.communityOf[graph.targets[e]];
        if (c1 == c2) continue;
        coarseEdgeSet.add(c1 <= c2 ? (c1, c2) : (c2, c1));
      }
    }

    final coarse = GraphCsr.fromEdges(coarseCount, coarseEdgeSet);
    ForceLayout.simulate(coarse, config: config);

    const golden = 2.399963229728653;
    final rankInCommunity = List<int>.filled(coarseCount, 0);
    for (var i = 0; i < n; i++) {
      final c = comm.communityOf[i];
      final rank = rankInCommunity[c]++;
      final r = 6.0 * math.sqrt(rank + 0.5);
      graph.positionsX[i] = coarse.positionsX[c] + r * math.cos(golden * rank);
      graph.positionsY[i] = coarse.positionsY[c] + r * math.sin(golden * rank);
    }

    return ForceLayout.simulate(graph, config: config, warmStart: true);
  }
}
