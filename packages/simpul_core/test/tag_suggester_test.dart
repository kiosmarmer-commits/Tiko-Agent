import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote _note(String path, String title, List<String> tags, String body) =>
    IndexedNote(
      path: path,
      title: title,
      mtimeNs: 0,
      sizeBytes: body.length,
      contentHash: 'h-$path',
      wordCount: 1,
      props: const {},
      tags: tags,
      aliases: const [],
      links: const [],
      chunks: [
        NoteChunk(
          headingPath: '',
          startChar: 0,
          endChar: body.length,
          text: body,
        ),
      ],
    );

void main() {
  test('saran tag dari centroid tag eksisting; tag milik sendiri dikecualikan',
      () {
    final notes = [
      _note('a.md', 'dart async', ['dart', 'programming'],
          'dart async await event loop isolate'),
      _note('b.md', 'dart isolate', ['dart', 'programming'],
          'dart isolate message passing event loop'),
      _note('c.md', 'resep rendang', ['cooking'],
          'rendang daging santan kelapa api kecil'),
      _note('d.md', 'dart futures', [],
          'dart future async await event loop microtask'),
    ];

    final suggestions = TagSuggester.suggest(notes);

    final forD = suggestions.where((s) => s.path == 'd.md').toList();
    expect(forD, isNotEmpty);
    expect(forD.map((s) => s.tag), everyElement(isNot('')));
    final forA = suggestions.where((s) => s.path == 'a.md').map((s) => s.tag);
    expect(forA, isNot(contains('dart')));
    expect(forA, isNot(contains('programming')));
  });

  test('deterministik: dua kali panggilan hasil identik', () {
    final notes = [
      _note('a.md', 'dart async', ['dart'], 'dart async await event loop'),
      _note('b.md', 'dart isolate', ['dart'], 'dart isolate event loop'),
      _note('c.md', 'rendang', ['cooking'], 'rendang santan kelapa'),
    ];
    expect(
      TagSuggester.suggest(notes).map((s) => (s.path, s.tag, s.score)),
      TagSuggester.suggest(notes).map((s) => (s.path, s.tag, s.score)),
    );
  });

  test('minScore menyaring saran lemah dan limit membatasi per catatan', () {
    final notes = [
      _note('a.md', 'dart async', ['dart'], 'dart async await event loop'),
      _note('b.md', 'resep rendang', ['cooking'], 'rendang santan kelapa'),
      _note('c.md', 'catatan acak xyz', [], 'qzx jkv wpl mnbbvf'),
    ];
    final strict = TagSuggester.suggest(notes, minScore: 0.99);
    expect(strict, isEmpty);

    final loose = TagSuggester.suggest(notes, minScore: 0.0, limit: 1);
    final perPath = <String, int>{};
    for (final s in loose) {
      perPath[s.path] = (perPath[s.path] ?? 0) + 1;
    }
    for (final count in perPath.values) {
      expect(count, lessThanOrEqualTo(1));
    }
  });

  test('vault melebihi batas → StateError (fail-closed)', () {
    final notes = [
      for (var i = 0; i < 5001; i++)
        _note('n$i.md', 't', const [], 'isi'),
    ];
    expect(() => TagSuggester.suggest(notes), throwsStateError);
  });
}
