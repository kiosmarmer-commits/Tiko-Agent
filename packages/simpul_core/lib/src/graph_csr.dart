import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'vault_index.dart';

/// Compressed Sparse Row graph over note links (GRA-D01/D02).
///
/// Node id = dense index 0..N-1 mapped to the sorted note path list, so all
/// access is direct array indexing (cache friendly, ~12 bytes/node for
/// positions plus 4 bytes per edge).
class GraphCsr {
  GraphCsr._(
    this.paths,
    this.offsets,
    this.targets,
    this.positionsX,
    this.positionsY,
  );

  final List<String> paths;
  final Uint32List offsets;
  final Uint32List targets;
  final Float32List positionsX;
  final Float32List positionsY;

  int get nodeCount => paths.length;
  int get edgeCount => targets.length;

  /// Builds the CSR from resolved links. Unresolved targets are ignored
  /// (they are reported by [VaultIndex.health] instead).
  static GraphCsr build(List<IndexedNote> notes) {
    final sorted = [...notes]..sort((a, b) => a.path.compareTo(b.path));
    final idByPath = <String, int>{};
    final byBasename = <String, String>{};
    final byPath = <String, String>{};
    for (var i = 0; i < sorted.length; i++) {
      final note = sorted[i];
      idByPath[note.path] = i;
      final withoutExt = note.path.replaceAll(RegExp(r'\.md$'), '');
      byPath[withoutExt] = note.path;
      byBasename.putIfAbsent(p.basename(withoutExt), () => note.path);
    }

    final edgeLists = List<List<int>>.generate(sorted.length, (_) => <int>[], growable: false);
    var edgeCount = 0;
    for (var i = 0; i < sorted.length; i++) {
      final seen = <String>{};
      for (final link in sorted[i].links) {
        if (link.embed || link.target.isEmpty) continue;
        if (!seen.add(link.target)) continue;
        final targetPath = resolveTarget(link.target, byBasename, byPath);
        final targetId = targetPath == null ? null : idByPath[targetPath];
        if (targetId == null || targetId == i) continue;
        edgeLists[i].add(targetId);
        edgeCount++;
      }
    }

    final offsets = Uint32List(sorted.length + 1);
    for (var i = 0; i < sorted.length; i++) {
      offsets[i + 1] = offsets[i] + edgeLists[i].length;
    }
    final targets = Uint32List(edgeCount);
    var cursor = 0;
    for (var i = 0; i < sorted.length; i++) {
      for (final target in edgeLists[i]) {
        targets[cursor++] = target;
      }
    }

    final positionsX = Float32List(sorted.length);
    final positionsY = Float32List(sorted.length);
    for (var i = 0; i < sorted.length; i++) {
      positionsX[i] = i.toDouble();
      positionsY[i] = 0;
    }
    return GraphCsr._(
      [for (final n in sorted) n.path],
      offsets,
      targets,
      positionsX,
      positionsY,
    );
  }

  /// Out-degree of a node (GRA-10: node size ∝ link count).
  int outDegree(int nodeId) => offsets[nodeId + 1] - offsets[nodeId];

  int inDegree(int nodeId) {
    var count = 0;
    for (final t in targets) {
      if (t == nodeId) count++;
    }
    return count;
  }

  /// N-hop neighbourhood (GRA-01: graph lokal) including the origin.
  Set<int> neighborhood(int nodeId, int hops) {
    final result = <int>{nodeId};
    var frontier = {nodeId};
    for (var h = 0; h < hops; h++) {
      final next = <int>{};
      for (final node in frontier) {
        for (var i = offsets[node]; i < offsets[node + 1]; i++) {
          if (result.add(targets[i])) next.add(targets[i]);
        }
      }
      if (next.isEmpty) break;
      frontier = next;
    }
    return result;
  }

  /// Orphan nodes: no inbound and no outbound edges (DIF-08).
  List<int> orphanNodes() {
    final hasOut = List<bool>.generate(nodeCount, (i) => offsets[i + 1] > offsets[i]);
    final hasIn = List<bool>.filled(nodeCount, false);
    for (final t in targets) {
      hasIn[t] = true;
    }
    return [
      for (var i = 0; i < nodeCount; i++)
        if (!hasOut[i] && !hasIn[i]) i,
    ];
  }
}
