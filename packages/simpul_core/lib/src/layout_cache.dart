import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'graph_cache.dart';
import 'graph_csr.dart';
import 'vault_index.dart';
import 'vault_index_sqlite_stub.dart'
    if (dart.library.ffi) 'vault_index_sqlite.dart';

/// Deterministic fingerprint of graph structure (nodes + edges); any change
/// to the vault topology invalidates the cached layout (NFR-S09).
String graphFingerprint(GraphCsr graph) {
  var hash = 0x811c9dc5;
  void mix(String s) {
    for (final code in utf8.encode(s)) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    hash ^= 0x0a;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }

  for (final path in graph.paths) {
    mix(path);
  }
  for (var i = 0; i < graph.nodeCount; i++) {
    for (var off = graph.offsets[i]; off < graph.offsets[i + 1]; off++) {
      mix('$i->${graph.targets[off]}');
    }
  }
  return hash.toRadixString(16);
}

/// Cache key for a layout run: algorithm version, iteration budget, and the
/// graph fingerprint so topology changes never reuse stale positions.
String layoutCacheVersion(
  GraphCsr graph, {
  required int iterations,
  bool multiLevel = false,
}) =>
    '${multiLevel ? 'multi-level-v1' : 'barnes-hut-v1'}:$iterations'
    ':${graphFingerprint(graph)}';

String layoutCacheKind({bool multiLevel = false}) =>
    multiLevel ? 'layout-multi-level' : 'layout';

/// Pre-fills [graph] positions from a cached payload; a stale-shaped payload
/// is ignored (cold start) instead of corrupting the simulation.
void applyWarmStart(GraphCsr graph, Map<String, Object?> payload) {
  final xs = payload['x'];
  final ys = payload['y'];
  if (xs is! List || ys is! List) return;
  if (xs.length != graph.nodeCount || ys.length != graph.nodeCount) return;
  for (var i = 0; i < graph.nodeCount; i++) {
    if (xs[i] is! num || ys[i] is! num) return;
  }
  for (var i = 0; i < graph.nodeCount; i++) {
    graph.positionsX[i] = (xs[i] as num).toDouble();
    graph.positionsY[i] = (ys[i] as num).toDouble();
  }
}

/// Best-effort cache store: only an already-existing index file is opened so
/// a bare vault never gets an index created just for caching.
GraphCacheStore? openVaultCacheStore(String vaultDir, {String? outDir}) {
  final dir = outDir ?? p.join(vaultDir, '.simpul');
  final sqlite = p.join(dir, 'index.db');
  final json = p.join(dir, 'index.json');
  final file = File(sqlite).existsSync()
      ? File(sqlite)
      : (File(json).existsSync() ? File(json) : File(sqlite));
  if (p.extension(file.path) == '.json') {
    return file.existsSync() ? JsonVaultIndex(file.path) : null;
  }
  return SqliteVaultIndex.tryOpen(file.path);
}
