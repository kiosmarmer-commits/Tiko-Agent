import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote _note(String path, String raw) {
  final parsed = NoteParser.parse(path, raw);
  return IndexedNote.fromParsed(parsed, 0, raw.length, 'hash-$path');
}

void main() {
  final notes = [
    _note('jaringan.md', '''
# Jaringan Neural
Jaringan neural konvolusional mengenali citra medis paru-paru.
Akurasi model CNN meningkat dengan augmentasi data.
Lihat [[pelatihan-model]].
'''),
    _note('pelatihan-model.md', '''
# Pelatihan Model
Pelatihan transformer membutuhkan GPU besar dan data besar.
Fine-tuning model kecil lebih murah dengan attention sparse.
'''),
    _note('resep.md', '''
# Resep Rendang
Rendang dimasak lama dengan santan dan rempah.
Bumbu halus penting untuk cita rasa rendang.
'''),
  ];

  test('GRAPH-1: build — community terdeteksi pada graph bertautan', () {
    final idx = GraphRagIndex();
    final count = idx.build(notes);
    expect(idx.built, isTrue);
    expect(idx.noteCount, 3);
    expect(count, greaterThanOrEqualTo(1));
  });

  test('GRAPH-2: local query — seed note + ekspansi hop ke tetangga', () {
    final idx = GraphRagIndex(maxHops: 2);
    idx.build(notes);
    final answer = idx.query('pelatihan transformer GPU besar');
    expect(answer.isEmpty, isFalse);
    expect(
      answer.sources.map((s) => s.path),
      contains('pelatihan-model.md'),
    );
    // Hop: tetangga wikilink ikut terangkat (jaringan.md menaut ke sini).
    expect(
      answer.sources.map((s) => s.path),
      contains('jaringan.md'),
    );
    expect(answer.context, contains('[1] '));
    expect(answer.sources.first.hops, 0);
  });

  test('GRAPH-3: query tidak relevan → jawaban kosong, tanpa raise', () {
    final idx = GraphRagIndex();
    idx.build(notes);
    final answer = idx.query('xyzzy kambing qwerty filosofi unik');
    expect(answer.isEmpty, isTrue);
    expect(answer.context, isEmpty);
  });

  test('GRAPH-4: query kosong / graph kosong → kosong tanpa raise', () {
    final idx = GraphRagIndex();
    expect(idx.build([]), 0);
    expect(idx.query('apa pun').isEmpty, isTrue);
    expect(idx.query('  ').isEmpty, isTrue);
  });

  test('GRAPH-5: deterministik — build+query sama → hasil sama', () {
    final a = GraphRagIndex()..build(notes);
    final b = GraphRagIndex()..build(notes);
    final qa = a.query('pelatihan model');
    final qb = b.query('pelatihan model');
    expect(
      [for (final s in qa.sources) s.toJson()],
      [for (final s in qb.sources) s.toJson()],
    );
  });
}
