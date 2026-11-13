import 'dart:isolate';
import 'dart:typed_data';

import 'force_layout.dart';
import 'graph_csr.dart';

/// Runs the Barnes-Hut layout in a worker isolate (NFR-S02, GRA-L01) and
/// hands the position buffers across isolates with `TransferableTypedData`
/// (NFR-S08, GRA-L06). The caller's [GraphCsr] positions are refreshed in
/// place after the simulation, so warm starts keep working (GRA-L02).
abstract final class IsolateLayout {
  static Future<LayoutResult> simulate(
    GraphCsr graph, {
    ForceLayoutConfig config = const ForceLayoutConfig(),
    bool warmStart = false,
  }) async {
    final n = graph.nodeCount;
    if (n == 0) {
      return const LayoutResult(iterations: 0, finalEnergy: 0, slept: true);
    }

    final offsets = _transfer(graph.offsets);
    final targets = _transfer(graph.targets);
    final positions = TransferableTypedData.fromList([
      graph.positionsX.buffer.asUint8List(
        graph.positionsX.offsetInBytes,
        graph.positionsX.lengthInBytes,
      ),
      graph.positionsY.buffer.asUint8List(
        graph.positionsY.offsetInBytes,
        graph.positionsY.lengthInBytes,
      ),
    ]);

    final (result, out) = await Isolate.run(() async {
      return _simulateIsolate(n, offsets, targets, positions, config, warmStart);
    });

    final materialized = out.materialize().asFloat32List();
    graph.positionsX.setAll(0, materialized.sublist(0, n));
    graph.positionsY.setAll(0, materialized.sublist(n, 2 * n));
    return result;
  }

  static TransferableTypedData _transfer(TypedData data) =>
      TransferableTypedData.fromList([
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      ]);
}

(LayoutResult, TransferableTypedData) _simulateIsolate(
  int n,
  TransferableTypedData offsets,
  TransferableTypedData targets,
  TransferableTypedData positions,
  ForceLayoutConfig config,
  bool warmStart,
) {
  final off = offsets.materialize().asUint32List();
  final tgt = targets.materialize().asUint32List();
  final pos = positions.materialize().asFloat32List();
  final x = Float32List.sublistView(pos, 0, n);
  final y = Float32List.sublistView(pos, n, 2 * n);

  final graph = GraphCsr.fromBuffers(
    paths: List.filled(n, ''),
    offsets: off,
    targets: tgt,
    positionsX: x,
    positionsY: y,
  );
  final result = ForceLayout.simulate(graph, config: config, warmStart: warmStart);

  final out = Float32List(2 * n);
  out.setAll(0, x);
  out.setAll(n, y);
  return (result, TransferableTypedData.fromList([out.buffer.asUint8List()]));
}
