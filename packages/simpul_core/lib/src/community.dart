import 'graph_csr.dart';

class CommunityResult {
  const CommunityResult({
    required this.communityOf,
    required this.communityCount,
    required this.modularity,
  });

  /// Community id per CSR node id (0..nodeCount-1).
  final List<int> communityOf;
  final int communityCount;
  final double modularity;
}

/// Louvain community detection over the CSR graph, treated as undirected
/// (GRA-L05). Deterministic: fixed node order, ties resolved by first
/// candidate, no RNG.
abstract final class CommunityDetector {
  static CommunityResult louvain(
    GraphCsr graph, {
    int maxLevels = 8,
    int maxPassesPerLevel = 12,
  }) {
    final n = graph.nodeCount;
    if (n == 0) {
      return const CommunityResult(
        communityOf: [],
        communityCount: 0,
        modularity: 0,
      );
    }

    var adj = _undirectedAdjacency(graph);
    var communityOf = List<int>.generate(n, (i) => i);

    for (var level = 0; level < maxLevels; level++) {
      final m = _totalMass(adj);
      final k = [
        for (final edges in adj) edges.fold(0.0, (sum, e) => sum + e.$2),
      ];
      final comm = _oneLevel(adj, m, k, maxPassesPerLevel);
      final (aggregated, mapping) = _aggregate(adj, comm);
      communityOf = [
        for (var i = 0; i < n; i++) mapping[comm[communityOf[i]]],
      ];
      if (aggregated.length == adj.length) break;
      adj = aggregated;
    }

    final renumbered = _renumber(communityOf);
    final fullAdj = _undirectedAdjacency(graph);
    final modularity = _modularity(fullAdj, renumbered);
    return CommunityResult(
      communityOf: renumbered,
      communityCount: _distinctCount(renumbered),
      modularity: modularity,
    );
  }

  /// One Louvain level: greedy modularity moves until no improvement.
  static List<int> _oneLevel(
    List<List<(int, double)>> adj,
    double m,
    List<double> k,
    int maxPasses,
  ) {
    final n = adj.length;
    final comm = List<int>.generate(n, (i) => i);
    final sigmaTot = [for (var i = 0; i < n; i++) k[i]];

    for (var pass = 0; pass < maxPasses; pass++) {
      var moved = 0;
      for (var i = 0; i < n; i++) {
        if (adj[i].isEmpty) continue;
        final ci = comm[i];
        final weightsTo = <int, double>{};
        for (final (j, w) in adj[i]) {
          if (j == i) continue;
          weightsTo[comm[j]] = (weightsTo[comm[j]] ?? 0) + w;
        }
        sigmaTot[ci] -= k[i];

        var bestComm = ci;
        var bestGain = 1e-12;
        for (final entry in weightsTo.entries) {
          final c = entry.key;
          final gain = entry.value / m - sigmaTot[c] * k[i] / (2 * m * m);
          if (gain > bestGain) {
            bestGain = gain;
            bestComm = c;
          }
        }
        sigmaTot[bestComm] += k[i];
        comm[i] = bestComm;
        if (bestComm != ci) moved++;
      }
      if (moved == 0) break;
    }
    return comm;
  }

  static List<List<(int, double)>> _undirectedAdjacency(GraphCsr graph) {
    final n = graph.nodeCount;
    final weight = <int, Map<int, double>>{};
    void addEdge(int a, int b, double w) {
      if (a == b) return;
      (weight[a] ??= {})[b] = ((weight[a]![b] ?? 0) + w);
    }

    for (var src = 0; src < n; src++) {
      for (var e = graph.offsets[src]; e < graph.offsets[src + 1]; e++) {
        addEdge(src, graph.targets[e], 1.0);
        addEdge(graph.targets[e], src, 1.0);
      }
    }

    return [
      for (var i = 0; i < n; i++)
        [
          for (final entry in (weight[i] ?? const <int, double>{}).entries)
            (entry.key, entry.value),
        ],
    ];
  }

  /// m = Σ_ij A_ij / 2 over ordered pairs; self-loops are stored once with
  /// weight 2w, so dividing the full adjacency sum by 2 is exact.
  static double _totalMass(List<List<(int, double)>> adj) {
    var all = 0.0;
    for (final edges in adj) {
      for (final (_, w) in edges) {
        all += w;
      }
    }
    return all / 2;
  }

  /// Returns the aggregated graph plus the mapping old community label ->
  /// aggregated node index, so callers can compose it with per-level
  /// assignments.
  static (List<List<(int, double)>>, List<int>) _aggregate(
    List<List<(int, double)>> adj,
    List<int> comm,
  ) {
    final newId = <int, int>{};
    for (final c in comm) {
      if (!newId.containsKey(c)) newId[c] = newId.length;
    }
    final mapping = [
      for (var i = 0; i < comm.length; i++) newId[comm[i]]!,
    ];
    final size = newId.length;
    final inter = List.generate(size, (_) => <int, double>{});
    final selfLoop = List.filled(size, 0.0);

    for (var i = 0; i < adj.length; i++) {
      final ci = newId[comm[i]]!;
      for (final (j, w) in adj[i]) {
        final cj = newId[comm[j]]!;
        if (ci == cj) {
          selfLoop[ci] += w;
        } else {
          inter[ci][cj] = (inter[ci][cj] ?? 0) + w;
        }
      }
    }

    return (
      [
        for (var c = 0; c < size; c++)
          [
            (c, selfLoop[c]),
            for (final entry in inter[c].entries) (entry.key, entry.value),
          ],
      ],
      mapping,
    );
  }

  static List<int> _renumber(List<int> assignment) {
    final newId = <int, int>{};
    return [
      for (final c in assignment)
        newId.putIfAbsent(c, () => newId.length),
    ];
  }

  static int _distinctCount(List<int> values) => values.toSet().length;

  /// Q = (1/2m) * Σ_ij [A_ij − k_i·k_j/(2m)]·δ(c_i, c_j) over ordered pairs.
  static double _modularity(List<List<(int, double)>> adj, List<int> comm) {
    final n = adj.length;
    final k = [
      for (final edges in adj) edges.fold(0.0, (sum, e) => sum + e.$2),
    ];
    final m = _totalMass(adj);
    if (m <= 0) return 0;

    var q = 0.0;
    for (var i = 0; i < n; i++) {
      var self = 0.0;
      for (final (j, w) in adj[i]) {
        if (j < i) continue;
        if (comm[i] != comm[j]) continue;
        if (j == i) {
          self = w;
        } else {
          q += 2 * (w - k[i] * k[j] / (2 * m));
        }
      }
      q += self - k[i] * k[i] / (2 * m);
    }
    return q / (2 * m);
  }
}
