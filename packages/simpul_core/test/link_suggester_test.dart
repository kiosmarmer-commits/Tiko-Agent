import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote note(
  String path,
  String text, {
  List<String> targets = const [],
  String? title,
}) =>
    IndexedNote(
      path: path,
      title: title ?? path,
      mtimeNs: 0,
      sizeBytes: 0,
      contentHash: 'hash-$path',
      wordCount: 10,
      props: const {},
      tags: const [],
      aliases: const [],
      links: [
        for (final t in targets)
          ParsedLink(
            target: t,
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: false,
            offset: 0,
          ),
      ],
      chunks: [
        NoteChunk(headingPath: '', startChar: 0, endChar: text.length, text: text),
      ],
    );

void main() {
  test('suggests semantically close unlinked pairs', () async {
    final suggestions = await LinkSuggester.suggest([
      note(
        'a.md',
        'jaringan saraf tiruan belajar dari data gambar berlabel',
        title: 'Jaringan Saraf Tiruan',
      ),
      note(
        'b.md',
        'model jaringan saraf tiruan dilatih pada gambar berlabel',
        title: 'Melatih Model Saraf Tiruan',
      ),
      note(
        'c.md',
        'resep rendang padang santan daging sapi',
        title: 'Resep Rendang Padang',
      ),
    ], minScore: 0.2);

    final pair = suggestions.where((s) =>
        (s.fromPath == 'a.md' && s.toPath == 'b.md') ||
        (s.fromPath == 'b.md' && s.toPath == 'a.md'));
    expect(pair, isNotEmpty);
    expect(
      suggestions.any((s) => s.fromPath == 'c.md' || s.toPath == 'c.md'),
      isFalse,
    );
  });

  test('already linked pairs are never suggested', () async {
    final suggestions = await LinkSuggester.suggest([
      note('a.md', 'topik yang sama sekali identik berdua ini', targets: ['b']),
      note('b.md', 'topik yang sama sekali identik berdua ini'),
    ], minScore: 0.1, limit: 50);

    expect(suggestions, isEmpty);
  });

  test('respects limit and min score', () async {
    final notes = [
      note('a.md', 'kata kunci bersama di banyak catatan uji'),
      for (var i = 0; i < 8; i++)
        note('n$i.md', 'kata kunci bersama di banyak catatan uji variasi $i'),
    ];
    final suggestions = await LinkSuggester.suggest(
      notes,
      minScore: 0.1,
      limit: 3,
    );
    expect(suggestions.length, 3);
    expect(suggestions.first.score, greaterThanOrEqualTo(suggestions.last.score));
  });

  test('refuses oversized vaults fail-closed', () async {
    final notes = [
      for (var i = 0; i < 5001; i++) note('n$i.md', 'teks $i'),
    ];
    expect(
      () => LinkSuggester.suggest(notes),
      throwsArgumentError,
    );
  });
}
