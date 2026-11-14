import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' show PointMode;
import 'package:path/path.dart' as p;
import 'package:simpul_core/simpul_core.dart';

/// Level of detail for the graph canvas (GRA-R03): far zoom draws community
/// aggregates, mid zoom draws individual nodes and edges, close zoom adds
/// labels.
enum GraphLod { aggregate, individual, detailed }

GraphLod lodForScale(double scale) {
  if (scale < 0.35) return GraphLod.aggregate;
  if (scale < 0.9) return GraphLod.individual;
  return GraphLod.detailed;
}

/// Node radius grows with its link count (GRA-10), clamped so hubs never
/// swallow the canvas.
double radiusForDegree(int degree) =>
    (4.0 + 2.0 * math.sqrt(degree)).clamp(4.0, 18.0).toDouble();

/// Deterministic folder-based hue (GRA-15): every note in the same folder
/// shares a color across sessions and devices.
Color folderColor(String path) {
  final folder = p.dirname(path);
  var hash = 0x811c9dc5;
  for (final code in utf8.encode(folder.toLowerCase())) {
    hash ^= code;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.62, 0.62).toColor();
}

/// Filter for the graph view (GRA-03): plain text matches path/title
/// substring; `tag:x` matches tags including nested prefixes.
bool matchesFilter(String path, String title, List<String> tags, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (q.startsWith('tag:')) {
    final tag = q.substring(4).trim();
    if (tag.isEmpty) return true;
    return tags.any(
      (t) {
        final lt = t.toLowerCase();
        return lt == tag || lt.startsWith('$tag/');
      },
    );
  }
  return path.toLowerCase().contains(q) || title.toLowerCase().contains(q);
}

class GraphViewController extends ChangeNotifier {
  GraphViewController({this.iterations = 300});

  final int iterations;

  GraphCsr? graph;
  QuadtreeIndex? tree;
  List<String> titles = const [];
  List<List<String>> noteTags = const [];
  List<int> communityOf = const [];
  Int32List degrees = Int32List(0);
  Rect worldBounds = Rect.zero;

  bool loading = false;
  bool warmStart = false;
  int ranIterations = 0;
  String? error;
  String filterQuery = '';
  int? hovered;
  int? selected;

  Set<int> get visibleIds {
    final graph = this.graph;
    if (graph == null) return const {};
    return {
      for (var i = 0; i < graph.nodeCount; i++)
        if (matchesFilter(graph.paths[i], titles[i], noteTags[i], filterQuery)) i,
    };
  }

  List<int> neighborsOf(int id) {
    final graph = this.graph;
    if (graph == null) return const [];
    final result = <int>[];
    for (var off = graph.offsets[id]; off < graph.offsets[id + 1]; off++) {
      final t = graph.targets[off];
      if (!result.contains(t)) result.add(t);
    }
    return result;
  }

  void setFilter(String query) {
    filterQuery = query;
    notifyListeners();
  }

  void setHovered(int? id) {
    if (hovered == id) return;
    hovered = id;
    notifyListeners();
  }

  void select(int? id) {
    selected = id;
    notifyListeners();
  }

  /// Loads the vault, lays out the graph with a warm start from the shared
  /// layout cache (GRA-L02/NFR-S09), and rebuilds the quadtree used for
  /// culling and hit-testing (GRA-R02).
  Future<void> load(String vaultDir) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final notes = await VaultScanner.scan(vaultDir);
      final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
      final config = ForceLayoutConfig(maxIterations: iterations);
      final kind = layoutCacheKind();
      final version = layoutCacheVersion(graph, iterations: iterations);
      final cache = openVaultCacheStore(vaultDir);
      Map<String, Object?>? cached;
      if (cache != null) {
        try {
          cached = await cache.loadGraphCache(kind: kind, version: version);
        } finally {
          await (cache as VaultIndex).close();
        }
      }
      if (cached != null) applyWarmStart(graph, cached);
      final result =
          ForceLayout.simulate(graph, config: config, warmStart: cached != null);
      if (cache != null) {
        final store = openVaultCacheStore(vaultDir);
        if (store != null) {
          try {
            await store.saveGraphCache(kind: kind, version: version, payload: {
              'x': [for (final x in graph.positionsX) x],
              'y': [for (final y in graph.positionsY) y],
            });
          } finally {
            await (store as VaultIndex).close();
          }
        }
      }

      var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0;
      if (graph.nodeCount > 0) {
        minX = maxX = graph.positionsX[0];
        minY = maxY = graph.positionsY[0];
        for (var i = 1; i < graph.nodeCount; i++) {
          if (graph.positionsX[i] < minX) minX = graph.positionsX[i];
          if (graph.positionsX[i] > maxX) maxX = graph.positionsX[i];
          if (graph.positionsY[i] < minY) minY = graph.positionsY[i];
          if (graph.positionsY[i] > maxY) maxY = graph.positionsY[i];
        }
      }

      final degrees = Int32List(graph.nodeCount);
      for (var i = 0; i < graph.nodeCount; i++) {
        degrees[i] = graph.offsets[i + 1] - graph.offsets[i];
      }
      final communities = CommunityDetector.louvain(graph);

      this.graph = graph;
      tree = QuadtreeIndex.build(graph.positionsX, graph.positionsY);
      titles = [for (final note in notes) note.parsed.title];
      noteTags = [for (final note in notes) List<String>.of(note.parsed.tags)];
      communityOf = List<int>.of(communities.communityOf);
      this.degrees = degrees;
      worldBounds = Rect.fromLTRB(minX - 60, minY - 60, maxX + 60, maxY + 60);
      warmStart = cached != null;
      ranIterations = result.iterations;
      hovered = null;
      selected = null;
    } catch (e) {
      error = e.toString();
      graph = null;
      tree = null;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}

/// Interactive vault graph (GRA-12 pan/zoom, GRA-13 hover highlight, GRA-14
/// tap to open). Rendering follows the PRD batching rules: nodes via
/// `drawRawPoints` (GRA-R01), edges as one `PointMode.lines` batch (GRA-R04),
/// viewport culling (GRA-R02), and LOD aggregation at far zoom (GRA-R03).
class GraphView extends StatefulWidget {
  const GraphView({
    super.key,
    required this.controller,
    this.onOpenNote,
  });

  final GraphViewController controller;
  final void Function(String path)? onOpenNote;

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  final TransformationController transformation = TransformationController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resetWhenGraphChanges);
  }

  @override
  void didUpdateWidget(covariant GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_resetWhenGraphChanges);
      widget.controller.addListener(_resetWhenGraphChanges);
    }
  }

  void _resetWhenGraphChanges() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resetWhenGraphChanges);
    transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final graph = controller.graph;
    if (graph == null) {
      return Center(
        child: Text(
          controller.loading
              ? 'Memuat graf...'
              : (controller.error ?? 'Vault belum dimuat'),
        ),
      );
    }
    final bounds = controller.worldBounds;
    return LayoutBuilder(
      builder: (context, constraints) {
        return InteractiveViewer(
          transformationController: transformation,
          constrained: false,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.02,
          maxScale: 8,
          child: SizedBox(
            width: math.max(bounds.width, 1),
            height: math.max(bounds.height, 1),
            child: MouseRegion(
              onHover: (event) {
                final world = transformation.toScene(event.localPosition);
                final scale = transformation.value.getMaxScaleOnAxis();
                final id = controller.tree?.hitTest(
                  world.dx,
                  world.dy,
                  radius: 12 / scale,
                );
                controller.setHovered(id);
              },
              onExit: (_) => controller.setHovered(null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final world =
                      transformation.toScene(details.localPosition);
                  final scale = transformation.value.getMaxScaleOnAxis();
                  final id = controller.tree?.hitTest(
                    world.dx,
                    world.dy,
                    radius: 12 / scale,
                  );
                  controller.select(id);
                  if (id != null && widget.onOpenNote != null) {
                    widget.onOpenNote!(controller.graph!.paths[id]);
                  }
                },
                child: CustomPaint(
                  painter: GraphPainter(
                    controller: controller,
                    scale: transformation.value.getMaxScaleOnAxis(),
                    viewport: _worldViewport(constraints),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Rect _worldViewport(BoxConstraints constraints) {
    final topLeft = transformation.toScene(Offset.zero);
    final bottomRight = transformation.toScene(
      Offset(constraints.maxWidth, constraints.maxHeight),
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }
}

class GraphPainter extends CustomPainter {
  GraphPainter({required this.controller, required this.scale, required this.viewport})
      : super(repaint: controller);

  final GraphViewController controller;
  final double scale;
  final Rect viewport;

  static const _edgeColor = Color(0x40FFFFFF);
  static const _nodeColor = Color(0xFF9AA4B2);
  static const _highlightColor = Color(0xFF7DD3FC);
  static const _maxLabels = 60;

  @override
  void paint(Canvas canvas, Size size) {
    final graph = controller.graph;
    if (graph == null || graph.nodeCount == 0) return;
    final lod = lodForScale(scale);
    final visible = controller.visibleIds;
    final x = graph.positionsX;
    final y = graph.positionsY;

    if (lod == GraphLod.aggregate) {
      _paintAggregated(canvas, graph, visible);
      return;
    }

    _paintEdges(canvas, graph, visible);
    _paintNodes(canvas, graph, visible);
    if (lod == GraphLod.detailed) {
      _paintLabels(canvas, graph, visible);
    }
    _paintHighlight(canvas, x, y);
  }

  void _paintAggregated(Canvas canvas, GraphCsr graph, Set<int> visible) {
    final communityOf = controller.communityOf;
    if (communityOf.isEmpty) {
      _paintNodes(canvas, graph, visible);
      return;
    }
    final sums = <int, List<double>>{};
    for (final i in visible) {
      final c = communityOf[i];
      final acc = sums.putIfAbsent(c, () => [0, 0, 0]);
      acc[0] += graph.positionsX[i];
      acc[1] += graph.positionsY[i];
      acc[2] += 1;
    }
    final edges = <int, Set<int>>{};
    for (var i = 0; i < graph.nodeCount; i++) {
      if (!visible.contains(i)) continue;
      for (var off = graph.offsets[i]; off < graph.offsets[i + 1]; off++) {
        final j = graph.targets[off];
        if (!visible.contains(j)) continue;
        final ci = communityOf[i];
        final cj = communityOf[j];
        if (ci == cj) continue;
        edges.putIfAbsent(math.min(ci, cj), () => {}).add(math.max(ci, cj));
      }
    }
    final linePoints = Float32List(edges.length * 8);
    var cursor = 0;
    for (final entry in edges.entries) {
      final a = sums[entry.key]!;
      final b = sums[entry.value.first]!;
      linePoints[cursor++] = a[0] / a[2];
      linePoints[cursor++] = a[1] / a[2];
      linePoints[cursor++] = b[0] / b[2];
      linePoints[cursor++] = b[1] / b[2];
    }
    if (cursor > 0) {
      canvas.drawRawPoints(
        PointMode.lines,
        Float32List.sublistView(linePoints, 0, cursor),
        Paint()
          ..color = _edgeColor
          ..strokeWidth = 1.5,
      );
    }
    final points = Float32List(sums.length * 2);
    cursor = 0;
    for (final acc in sums.values) {
      points[cursor++] = acc[0] / acc[2];
      points[cursor++] = acc[1] / acc[2];
    }
    canvas.drawRawPoints(
      PointMode.points,
      Float32List.sublistView(points, 0, cursor),
      Paint()
        ..color = _nodeColor
        ..strokeWidth = 10 + 2 * math.sqrt(sums.length)
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintEdges(Canvas canvas, GraphCsr graph, Set<int> visible) {
    final x = graph.positionsX;
    final y = graph.positionsY;
    final culled = <int>[];
    for (var i = 0; i < graph.nodeCount; i++) {
      if (!visible.contains(i)) continue;
      if (!_inViewport(x[i], y[i])) continue;
      culled.add(i);
    }
    final visibleSet = culled.toSet();
    var count = 0;
    for (final i in culled) {
      for (var off = graph.offsets[i]; off < graph.offsets[i + 1]; off++) {
        if (visibleSet.contains(graph.targets[off])) count++;
      }
    }
    if (count == 0) return;
    final points = Float32List(count * 4);
    var cursor = 0;
    for (final i in culled) {
      for (var off = graph.offsets[i]; off < graph.offsets[i + 1]; off++) {
        final j = graph.targets[off];
        if (!visibleSet.contains(j)) continue;
        points[cursor++] = x[i];
        points[cursor++] = y[i];
        points[cursor++] = x[j];
        points[cursor++] = y[j];
      }
    }
    canvas.drawRawPoints(
      PointMode.lines,
      Float32List.sublistView(points, 0, cursor),
      Paint()
        ..color = _edgeColor
        ..strokeWidth = 1 / scale.clamp(0.5, 4.0),
    );
  }

  void _paintNodes(Canvas canvas, GraphCsr graph, Set<int> visible) {
    final x = graph.positionsX;
    final y = graph.positionsY;
    final buckets = <int, List<int>>{};
    for (final i in visible) {
      if (!_inViewport(x[i], y[i])) continue;
      buckets.putIfAbsent(radiusForDegree(controller.degrees[i]).round(), () => []).add(i);
    }
    for (final entry in buckets.entries) {
      final ids = entry.value;
      final points = Float32List(ids.length * 2);
      for (var k = 0; k < ids.length; k++) {
        points[k * 2] = x[ids[k]];
        points[k * 2 + 1] = y[ids[k]];
      }
      canvas.drawRawPoints(
        PointMode.points,
        points,
        Paint()
          ..color = _nodeColor
          ..strokeWidth = entry.key.toDouble()
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _paintLabels(Canvas canvas, GraphCsr graph, Set<int> visible) {
    final x = graph.positionsX;
    final y = graph.positionsY;
    final labeled = <int>{};
    final hovered = controller.hovered;
    final selected = controller.selected;
    for (final id in [if (hovered != null) hovered, if (selected != null) selected]) {
      labeled.add(id);
      labeled.addAll(controller.neighborsOf(id));
    }
    if (labeled.length < _maxLabels) {
      final candidates = [
        for (final i in visible)
          if (!labeled.contains(i) && _inViewport(x[i], y[i])) i,
      ]..sort((a, b) => controller.degrees[b].compareTo(controller.degrees[a]));
      labeled.addAll(candidates.take(_maxLabels - labeled.length));
    }
    final paint = TextPainter()
      ..textDirection = TextDirection.ltr
      ..maxLines = 1;
    for (final i in labeled) {
      paint.text = TextSpan(
        text: controller.titles[i],
        style: const TextStyle(color: Color(0xDDEEEEEE), fontSize: 11),
      );
      paint.layout();
      paint.paint(canvas, Offset(x[i] + 8, y[i] - 6));
    }
  }

  void _paintHighlight(Canvas canvas, Float32List x, Float32List y) {
    final focus = controller.hovered ?? controller.selected;
    if (focus == null) return;
    final canvasPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = _highlightColor;
    canvas.drawCircle(Offset(x[focus], y[focus]), radiusForDegree(controller.degrees[focus]) + 4, canvasPaint);
    for (final n in controller.neighborsOf(focus)) {
      canvas.drawCircle(Offset(x[n], y[n]), radiusForDegree(controller.degrees[n]) + 3, canvasPaint..color = _highlightColor.withValues(alpha: 0.6));
    }
  }

  bool _inViewport(double px, double py) {
    final margin = 40 / scale.clamp(0.02, 8.0);
    return px >= viewport.left - margin &&
        px <= viewport.right + margin &&
        py >= viewport.top - margin &&
        py <= viewport.bottom + margin;
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) =>
      oldDelegate.scale != scale ||
      oldDelegate.viewport != viewport ||
      oldDelegate.controller != controller;
}

/// Full page hosting the graph view: vault path, load button, filter field,
/// and a status line. Local-first — reads the vault directly (desktop).
class SimpulGraphPage extends StatefulWidget {
  const SimpulGraphPage({super.key, this.initialVault = ''});

  final String initialVault;

  @override
  State<SimpulGraphPage> createState() => _SimpulGraphPageState();
}

class _SimpulGraphPageState extends State<SimpulGraphPage> {
  final GraphViewController controller = GraphViewController();
  late final TextEditingController vaultField;
  final TextEditingController filterField = TextEditingController();

  @override
  void initState() {
    super.initState();
    vaultField = TextEditingController(text: widget.initialVault);
    controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    controller.dispose();
    vaultField.dispose();
    filterField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = controller.graph;
    return Scaffold(
      appBar: AppBar(title: const Text('Graf Vault (Simpul)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: vaultField,
                    decoration: const InputDecoration(
                      hintText: 'Path vault lokal (mis. ~/vault)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: controller.loading ? null : _load,
                  child: const Text('Muat'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: filterField,
              decoration: const InputDecoration(
                hintText: 'Filter: teks bebas atau tag:x (GRA-03)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: controller.setFilter,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _status(graph),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: GraphView(
              controller: controller,
              onOpenNote: (path) => _openNote(context, path),
            ),
          ),
        ],
      ),
    );
  }

  String _status(GraphCsr? graph) {
    if (controller.loading) return 'Memuat...';
    if (graph == null) return 'Belum ada graf — isi path vault lalu Muat.';
    return 'node: ${graph.nodeCount} | edge: ${graph.targets.length} | '
        'iterasi: ${controller.ranIterations} | warm start: ${controller.warmStart}';
  }

  Future<void> _load() async {
    final dir = vaultField.text.trim();
    if (dir.isEmpty) return;
    await controller.load(dir);
  }

  void _openNote(BuildContext context, String path) {
    final vault = vaultField.text.trim();
    final file = p.join(vault, path);
    if (!File(file).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Catatan tidak ditemukan: $path')),
      );
      return;
    }
    var content = File(file).readAsStringSync();
    if (content.length > 20000) content = content.substring(0, 20000);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(path),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }
}
