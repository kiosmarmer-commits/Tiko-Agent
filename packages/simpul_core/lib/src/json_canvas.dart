import 'dart:convert';

import 'package:path/path.dart' as p;

import 'force_layout.dart';
import 'graph_csr.dart';
import 'vault_index.dart';

class JsonCanvasException implements Exception {
  const JsonCanvasException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One node of a JSON Canvas document (FR-41, spec jsoncanvas.org): `text`,
/// `file`, `link`, or `group`. x/y is the top-left corner in canvas
/// coordinates; color is a spec palette index "1".."6".
class JsonCanvasNode {
  const JsonCanvasNode({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.color,
    this.text,
    this.file,
    this.url,
    this.label,
  });

  final String id;
  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final String? color;
  final String? text;
  final String? file;
  final String? url;
  final String? label;

  static const knownTypes = {'text', 'file', 'link', 'group'};

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        if (color != null) 'color': color,
        if (text != null) 'text': text,
        if (file != null) 'file': file,
        if (url != null) 'url': url,
        if (label != null) 'label': label,
      };

  static JsonCanvasNode fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final type = json['type'];
    if (id is! String || id.isEmpty) {
      throw const JsonCanvasException('node butuh "id" string non-kosong');
    }
    if (type is! String || !knownTypes.contains(type)) {
      throw JsonCanvasException(
        'node $id punya tipe tidak dikenal: $type '
        '(dikenal: text, file, link, group)',
      );
    }
    for (final key in ['x', 'y', 'width', 'height']) {
      if (json[key] is! num) {
        throw JsonCanvasException('node $id butuh "$key" angka');
      }
    }
    return JsonCanvasNode(
      id: id,
      type: type,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      color: json['color'] as String?,
      text: json['text'] as String?,
      file: json['file'] as String?,
      url: json['url'] as String?,
      label: json['label'] as String?,
    );
  }
}

/// One edge of a JSON Canvas document: a directed connection between two
/// node ids, with optional label, color, and sides.
class JsonCanvasEdge {
  const JsonCanvasEdge({
    required this.id,
    required this.fromNode,
    required this.toNode,
    this.fromSide,
    this.toSide,
    this.label,
    this.color,
  });

  final String id;
  final String fromNode;
  final String toNode;
  final String? fromSide;
  final String? toSide;
  final String? label;
  final String? color;

  Map<String, Object?> toJson() => {
        'id': id,
        'fromNode': fromNode,
        'toNode': toNode,
        if (fromSide != null) 'fromSide': fromSide,
        if (toSide != null) 'toSide': toSide,
        if (label != null) 'label': label,
        if (color != null) 'color': color,
      };

  static JsonCanvasEdge fromJson(Map<String, Object?> json) {
    for (final key in ['id', 'fromNode', 'toNode']) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw JsonCanvasException('edge butuh "$key" string non-kosong');
      }
    }
    return JsonCanvasEdge(
      id: json['id'] as String,
      fromNode: json['fromNode'] as String,
      toNode: json['toNode'] as String,
      fromSide: json['fromSide'] as String?,
      toSide: json['toSide'] as String?,
      label: json['label'] as String?,
      color: json['color'] as String?,
    );
  }
}

/// A parsed `.canvas` document (FR-41): nodes + edges, encodable to the
/// Obsidian-compatible JSON Canvas format and decodable back.
class JsonCanvasDocument {
  const JsonCanvasDocument({required this.nodes, required this.edges});

  final List<JsonCanvasNode> nodes;
  final List<JsonCanvasEdge> edges;

  String encode() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'nodes': [for (final node in nodes) node.toJson()],
      'edges': [for (final edge in edges) edge.toJson()],
    });
  }

  static JsonCanvasDocument decode(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw JsonCanvasException('bukan JSON valid: ${e.message}');
    }
    if (decoded is! Map) {
      throw const JsonCanvasException('dokumen canvas harus objek JSON');
    }
    final nodesRaw = decoded['nodes'];
    final edgesRaw = decoded['edges'];
    if (nodesRaw is! List) {
      throw const JsonCanvasException('dokumen canvas butuh "nodes" array');
    }
    return JsonCanvasDocument(
      nodes: [
        for (final node in nodesRaw)
          JsonCanvasNode.fromJson((node as Map).cast<String, Object?>()),
      ],
      edges: [
        if (edgesRaw is List)
          for (final edge in edgesRaw)
            JsonCanvasEdge.fromJson((edge as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// Exports a vault graph as an Obsidian-compatible `.canvas` document
/// (FR-41): every note becomes a `file` node placed by the force layout,
/// every resolved link becomes an edge, and folders map to the spec color
/// palette deterministically.
abstract final class VaultCanvas {
  static const nodeWidth = 260.0;
  static const nodeHeight = 120.0;
  static const spread = 2.0;

  static JsonCanvasDocument fromNotes(
    List<IndexedNote> notes, {
    ForceLayoutConfig config = const ForceLayoutConfig(maxIterations: 200),
  }) {
    final graph = GraphCsr.build(notes);
    ForceLayout.simulate(graph, config: config);
    final n = graph.nodeCount;
    var minX = 0.0, minY = 0.0;
    for (var i = 0; i < n; i++) {
      if (i == 0 || graph.positionsX[i] < minX) minX = graph.positionsX[i];
      if (i == 0 || graph.positionsY[i] < minY) minY = graph.positionsY[i];
    }
    final nodes = [
      for (var i = 0; i < n; i++)
        JsonCanvasNode(
          id: 'n$i',
          type: 'file',
          x: (graph.positionsX[i] - minX) * spread,
          y: (graph.positionsY[i] - minY) * spread,
          width: nodeWidth,
          height: nodeHeight,
          color: paletteColor(graph.paths[i]),
          file: graph.paths[i],
        ),
    ];
    final edges = <JsonCanvasEdge>[];
    for (var i = 0; i < n; i++) {
      for (var off = graph.offsets[i]; off < graph.offsets[i + 1]; off++) {
        final j = graph.targets[off];
        edges.add(JsonCanvasEdge(
          id: 'e${edges.length}',
          fromNode: 'n$i',
          toNode: 'n$j',
        ));
      }
    }
    return JsonCanvasDocument(nodes: nodes, edges: edges);
  }

  /// Deterministic folder → spec palette ("1".."6") mapping.
  static String? paletteColor(String path) {
    final folder = p.dirname(path);
    if (folder == '.') return null;
    var hash = 0x811c9dc5;
    for (final code in folder.toLowerCase().codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${(hash % 6) + 1}';
  }
}
