import 'dart:convert';
import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('JsonCanvasDocument (FR-41)', () {
    const sample = '''
{
  "nodes": [
    {"id": "a", "type": "text", "x": 0, "y": 0, "width": 250, "height": 60, "text": "halo"},
    {"id": "b", "type": "file", "x": 400, "y": 0, "width": 250, "height": 60, "file": "ml/saraf.md", "color": "3"},
    {"id": "c", "type": "link", "x": 800, "y": 0, "width": 250, "height": 60, "url": "https://example.com"},
    {"id": "g", "type": "group", "x": -100, "y": -100, "width": 1200, "height": 300, "label": "ML"}
  ],
  "edges": [
    {"id": "e1", "fromNode": "a", "toNode": "b", "label": "menjelaskan", "color": "2"},
    {"id": "e2", "fromNode": "b", "toNode": "c", "fromSide": "right", "toSide": "left"}
  ]
}
''';

    test('decode mengenali semua tipe node dan atribut edge', () {
      final doc = JsonCanvasDocument.decode(sample);
      expect(doc.nodes, hasLength(4));
      expect(doc.nodes.map((n) => n.type),
          containsAll(['text', 'file', 'link', 'group']));
      final fileNode = doc.nodes.firstWhere((n) => n.type == 'file');
      expect(fileNode.file, 'ml/saraf.md');
      expect(fileNode.color, '3');
      expect(doc.edges, hasLength(2));
      expect(doc.edges.first.label, 'menjelaskan');
      expect(doc.edges.last.fromSide, 'right');
    });

    test('encode → decode roundtrip mempertahankan isi', () {
      final doc = JsonCanvasDocument.decode(sample);
      final reparsed = JsonCanvasDocument.decode(doc.encode());
      expect(reparsed.nodes.length, doc.nodes.length);
      expect(reparsed.edges.length, doc.edges.length);
      final node = reparsed.nodes.firstWhere((n) => n.id == 'b');
      expect(node.file, 'ml/saraf.md');
      expect(node.x, 400);
      final edge = reparsed.edges.first;
      expect(edge.fromNode, 'a');
      expect(edge.toNode, 'b');
      expect(edge.label, 'menjelaskan');
    });

    test('hasil encode bisa dibaca Obsidian: kunci wajib ada', () {
      final decoded =
          jsonDecode(JsonCanvasDocument.decode(sample).encode()) as Map;
      expect(decoded['nodes'], isA<List>());
      expect(decoded['edges'], isA<List>());
      for (final node in (decoded['nodes'] as List)) {
        expect((node as Map)['id'], isA<String>());
        expect(node['x'], isA<num>());
        expect(node['width'], isA<num>());
      }
    });

    test('decode menolak dokumen tidak valid dengan pesan jelas', () {
      expect(
        () => JsonCanvasDocument.decode('[]'),
        throwsA(isA<JsonCanvasException>()),
      );
      expect(
        () => JsonCanvasDocument.decode('{"edges": []}'),
        throwsA(isA<JsonCanvasException>()),
      );
      expect(
        () => JsonCanvasDocument.decode(
          '{"nodes": [{"type": "text", "x": 0, "y": 0, "width": 1, "height": 1}]}',
        ),
        throwsA(isA<JsonCanvasException>()),
      );
      expect(
        () => JsonCanvasDocument.decode(
          '{"nodes": [{"id": "x", "type": "aneh", "x": 0, "y": 0, "width": 1, "height": 1}]}',
        ),
        throwsA(isA<JsonCanvasException>()),
      );
      expect(
        () => JsonCanvasDocument.decode(
          '{"nodes": [], "edges": [{"id": "e", "fromNode": "a"}]}',
        ),
        throwsA(isA<JsonCanvasException>()),
      );
      expect(
        () => JsonCanvasDocument.decode('{bukan json'),
        throwsA(isA<JsonCanvasException>()),
      );
    });
  });

  group('VaultCanvas.fromNotes (FR-41)', () {
    late Directory tmp;
    late String vault;
    late JsonCanvasDocument doc;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('simpul-canvas-test');
      vault = '${tmp.path}/vault';
      await Directory('$vault/ml').create(recursive: true);
      await Directory('$vault/ops').create(recursive: true);
      await File('$vault/ml/saraf.md').writeAsString(
        '---\ntitle: Saraf\n---\nlihat [[gd]]\n',
      );
      await File('$vault/ml/gd.md').writeAsString(
        '---\ntitle: GD\n---\nteks gradient descent\n',
      );
      await File('$vault/ops/deploy.md').writeAsString(
        '---\ntitle: Deploy\n---\ndocker dan CI\n',
      );
      final notes = await VaultScanner.scan(vault);
      doc = VaultCanvas.fromNotes(notes.map((n) => n.toIndexed()).toList());
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('tiap catatan menjadi node file dengan path vault-relatif', () {
      expect(doc.nodes, hasLength(3));
      expect(doc.nodes.map((n) => n.file),
          containsAll(['ml/saraf.md', 'ml/gd.md', 'ops/deploy.md']));
      for (final node in doc.nodes) {
        expect(node.type, 'file');
        expect(node.width, VaultCanvas.nodeWidth);
        expect(node.height, VaultCanvas.nodeHeight);
        expect(node.x.isFinite, isTrue);
        expect(node.y.isFinite, isTrue);
        expect(node.x, greaterThanOrEqualTo(0));
        expect(node.y, greaterThanOrEqualTo(0));
      }
    });

    test('tautan ter-resolve menjadi edge', () {
      expect(doc.edges, hasLength(1));
      final from = doc.nodes
          .firstWhere((n) => n.file == 'ml/saraf.md')
          .id;
      final to = doc.nodes.firstWhere((n) => n.file == 'ml/gd.md').id;
      expect(doc.edges.first.fromNode, from);
      expect(doc.edges.first.toNode, to);
    });

    test('warna palet deterministik per folder dan valid 1..6', () {
      final saraf = doc.nodes.firstWhere((n) => n.file == 'ml/saraf.md');
      final deploy = doc.nodes.firstWhere((n) => n.file == 'ops/deploy.md');
      expect(saraf.color, VaultCanvas.paletteColor('ml/gd.md'));
      expect(saraf.color, isNot(deploy.color));
      for (final node in doc.nodes) {
        if (node.color != null) {
          expect(int.parse(node.color!), inInclusiveRange(1, 6));
        }
      }
      expect(VaultCanvas.paletteColor('catatan.md'), isNull);
    });

    test('dokumen hasil ekspor lolos decode sendiri (format valid)', () {
      final reparsed = JsonCanvasDocument.decode(doc.encode());
      expect(reparsed.nodes.length, 3);
      expect(reparsed.edges.length, 1);
    });
  });
}
