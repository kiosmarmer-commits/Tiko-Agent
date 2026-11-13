import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('frontmatter', () {
    test('parses scalar, list, bool, and number properties', () {
      final note = NoteParser.parse(
        'catatan/ide.md',
        '---\n'
        'title: Catatan Uji\n'
        'tags:\n'
        '  - riset\n'
        '  - proyek/alpha\n'
        'aliases:\n'
        '  - "Nama Lain"\n'
        'pinned: true\n'
        'rating: 4\n'
        '---\n'
        'Isi catatan.\n',
      );
      expect(note.title, 'Catatan Uji');
      expect(note.tags, containsAll(['riset', 'proyek/alpha']));
      expect(note.aliases, ['Nama Lain']);
      expect(note.props['pinned'], true);
      expect(note.props['rating'], 4);
      expect(note.body, 'Isi catatan.\n');
      expect(note.wordCount, 2);
    });

    test('falls back to basename as title', () {
      final note = NoteParser.parse('jurnal/2026-11-13.md', 'Isi.\n');
      expect(note.title, '2026-11-13');
      expect(note.props, isEmpty);
    });

    test('supports inline list syntax', () {
      final note = NoteParser.parse('a.md', '---\ntags: [a, b]\n---\n');
      expect(note.tags, containsAll(['a', 'b']));
    });
  });

  group('wikilinks', () {
    test('parses all Obsidian variants', () {
      final note = NoteParser.parse(
        'n.md',
        '[[Note]] [[Note.md]] [[folder/Note]] [[Note|Tampil]] '
        '[[Note#Heading]] [[Note#^block-1]] [[#Heading]]',
      );
      final targets = note.links.map((l) => l.target).toList();
      expect(targets, containsAll(['Note', 'folder/Note']));
      expect(targets, isNot(contains('Note.md')));
      final aliased = note.links.firstWhere((l) => l.alias == 'Tampil');
      expect(aliased.target, 'Note');
      final withAnchor = note.links.firstWhere((l) => l.anchor == '^block-1');
      expect(withAnchor.target, 'Note');
      final sameNote = note.links.firstWhere((l) => l.target.isEmpty);
      expect(sameNote.anchor, 'Heading');
      expect(note.links.map((l) => l.kind), everyElement('wikilink'));
    });

    test('parses embeds separately from links', () {
      final note = NoteParser.parse('n.md', '![[img.png|300]] dan [[Note]]');
      final embed = note.links.firstWhere((l) => l.embed);
      expect(embed.target, 'img.png');
      expect(embed.alias, '300');
      expect(note.links.where((l) => !l.embed).length, 1);
    });

    test('parses markdown links with percent encoding', () {
      final note = NoteParser.parse(
        'n.md',
        '[Teks](folder/My%20Note.md) dan [Web](https://contoh.id) dan [anchor](#Bagian)',
      );
      expect(note.links.length, 1);
      expect(note.links.single.kind, 'mdlink');
      expect(note.links.single.target, 'folder/My Note');
      expect(note.links.single.alias, 'Teks');
    });

    test('ignores wikilinks inside code and comments', () {
      final note = NoteParser.parse(
        'n.md',
        '```\n[[DalamKode]]\n```\n`[[DalamInline]]`\n%%[[DalamKomentar]]%%\n',
      );
      expect(note.links, isEmpty);
    });

    test('records link offsets within the body', () {
      final note = NoteParser.parse('n.md', 'awal [[Target]] akhir');
      expect(note.links.single.offset, 5);
    });
  });

  group('tags', () {
    test('parses inline tags and rejects invalid ones', () {
      final note = NoteParser.parse(
        'n.md',
        '#tag/induk isi #sederhana, #123 #tanpa-spasi. (#dalam kurung)',
      );
      expect(note.tags, containsAll(['tag/induk', 'sederhana', 'tanpa-spasi', 'dalam']));
      expect(note.tags, isNot(contains('123')));
    });

    test('does not treat headings as tags', () {
      final note = NoteParser.parse('n.md', '# Judul Heading\nisi');
      expect(note.tags, isEmpty);
    });
  });

  group('block ids and chunks', () {
    test('extracts block ids', () {
      final note = NoteParser.parse('n.md', 'paragraf satu ^abc-123\nparagraf dua');
      expect(note.blockIds, ['abc-123']);
    });

    test('chunks by heading chain', () {
      final note = NoteParser.parse(
        'n.md',
        'intro\n# Satu\nisi satu\n## Dua\nisi dua\n# Tiga\nisi tiga\n',
      );
      final paths = note.chunks.map((c) => c.headingPath).toList();
      expect(paths, ['', 'Satu', 'Satu > Dua', 'Tiga']);
      expect(note.chunks.first.text, contains('intro'));
      expect(note.chunks[2].text, contains('isi dua'));
    });

    test('falls back to a single chunk without headings', () {
      final note = NoteParser.parse('n.md', 'tanpa heading sama sekali');
      expect(note.chunks.length, 1);
      expect(note.chunks.single.headingPath, '');
    });
  });
}
