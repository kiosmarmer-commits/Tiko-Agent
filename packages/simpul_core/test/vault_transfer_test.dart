import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul_transfer_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('VaultImporter', () {
    test('obsidian import copies notes and attachments, skips hidden', () async {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      File('${src.path}/note.md').writeAsStringSync('# Hello');
      Directory('${src.path}/sub').createSync();
      File('${src.path}/sub/deep.md').writeAsStringSync('body');
      File('${src.path}/img.png').writeAsBytesSync([1, 2, 3]);
      Directory('${src.path}/.obsidian').createSync();
      File('${src.path}/.obsidian/config.json').writeAsStringSync('{}');

      final dest = Directory('${tmp.path}/dest');
      final result = await VaultImporter.importFolder(src, dest,
          format: ImportFormat.obsidian);
      expect(result.notesCopied, 2);
      expect(result.attachmentsCopied, 1);
      expect(File('${dest.path}/note.md').readAsStringSync(), '# Hello');
      expect(File('${dest.path}/sub/deep.md').existsSync(), isTrue);
      expect(File('${dest.path}/.obsidian/config.json').existsSync(), isFalse);
    });

    test('notion import strips 32-hex uuid suffixes from names and links',
        () async {
      final src = Directory('${tmp.path}/notion')..createSync(recursive: true);
      File('${src.path}/My Page 3f2a9c8e1b7d4f5a6e0c2d1b8a7f9e3c.md')
          .writeAsStringSync('see [Other Page 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d]'
              '(Other%20Page%201a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d)');
      final dest = Directory('${tmp.path}/dest2');
      final result = await VaultImporter.importFolder(src, dest,
          format: ImportFormat.notion);
      expect(result.notesCopied, 1);
      final imported = File('${dest.path}/My Page.md');
      expect(imported.existsSync(), isTrue);
      final body = imported.readAsStringSync();
      expect(body, isNot(contains('1a2b3c4d')));
      expect(body, contains('(Other%20Page)'));
    });

    test('notion import deduplicates colliding flattened names', () async {
      final src = Directory('${tmp.path}/notion2')..createSync(recursive: true);
      File('${src.path}/Note aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md')
          .writeAsStringSync('one');
      File('${src.path}/Note bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md')
          .writeAsStringSync('two');
      final dest = Directory('${tmp.path}/dest3');
      final result = await VaultImporter.importFolder(src, dest,
          format: ImportFormat.notion);
      expect(result.notesCopied, 2);
      expect(File('${dest.path}/Note.md').existsSync(), isTrue);
      expect(File('${dest.path}/Note 2.md').existsSync(), isTrue);
    });

    test('logseq import flattens pages and rewrites block refs', () async {
      final src = Directory('${tmp.path}/logseq')..createSync(recursive: true);
      Directory('${src.path}/pages').createSync();
      File('${src.path}/pages/journal.md')
          .writeAsStringSync('ref ((abc123de)) and [[other]]');
      Directory('${src.path}/logseq').createSync();
      File('${src.path}/logseq/config.json').writeAsStringSync('{}');
      final dest = Directory('${tmp.path}/dest4');
      final result = await VaultImporter.importFolder(src, dest,
          format: ImportFormat.logseq);
      expect(result.notesCopied, 1);
      expect(result.linksRewritten, 1);
      final body = File('${dest.path}/pages/journal.md').readAsStringSync();
      expect(body, contains('`block:abc123de`'));
      expect(body, contains('[[other]]'));
    });

    test('missing source throws fail-closed', () async {
      final dest = Directory('${tmp.path}/never');
      await expectLater(
        VaultImporter.importFolder(Directory('${tmp.path}/nope'), dest),
        throwsStateError,
      );
    });
  });

  group('VaultExporter.noteToHtml', () {
    test('renders headings, emphasis, code, lists, checkboxes', () {
      final html = VaultExporter.noteToHtml(
        '# Title\n\n**bold** and *italic* and `code`\n\n'
        '- item one\n- item two\n\n'
        '- [ ] todo\n- [x] done\n\n> quoted\n\n'
        '<h1>raw</h1>\n\n'
        '```dart\nvoid main() {}\n```\n',
        title: 'T',
      );
      expect(html, contains('<h1>Title</h1>'));
      expect(html, contains('&lt;h1&gt;raw&lt;/h1&gt;'));
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<em>italic</em>'));
      expect(html, contains('<code>code</code>'));
      expect(html, contains('<li>item one</li>'));
      expect(html, contains('type="checkbox"'));
      expect(html, contains(' checked'));
      expect(html, contains('<blockquote>quoted</blockquote>'));
    });

    test('wikilinks become spans with data-target', () {
      final html = VaultExporter.noteToHtml('see [[Other Page|alias]]');
      expect(html, contains('class="wikilink" data-target="Other Page"'));
      expect(html, contains('>alias<'));
    });

    test('escapes html special characters', () {
      final html = VaultExporter.noteToHtml('<script>alert(1)</script>');
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('VaultExporter graph formats', () {
    test('graphToJson emits nodes and edges from CSR', () {
      final g = GraphCsr.fromEdges(3, [(0, 1), (1, 2)]);
      g.paths[0] = 'a.md';
      g.paths[1] = 'b.md';
      g.paths[2] = 'c.md';
      g.positionsX[0] = 1.5;
      g.positionsY[0] = 2.5;
      final json = VaultExporter.graphToJson(g);
      expect(json['nodes'] as List, hasLength(3));
      expect(json['edges'] as List, hasLength(2));
      expect((json['nodes'] as List).first['id'], 'a.md');
      expect(
        (json['edges'] as List)
            .map((e) => '${e['source']}->${e['target']}'),
        containsAll(['a.md->b.md', 'b.md->c.md']),
      );
    });

    test('graphToGraphml produces valid GraphML skeleton', () {
      final g = GraphCsr.fromEdges(2, [(0, 1)]);
      g.paths[0] = 'a.md';
      g.paths[1] = 'b.md';
      final xml = VaultExporter.graphToGraphml(g);
      expect(xml, contains('<graphml'));
      expect(xml, contains('<node id='));
      expect(xml, contains('<edge source='));
      expect(xml, contains('</graphml>'));
    });
  });
}
