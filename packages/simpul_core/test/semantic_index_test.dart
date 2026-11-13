import 'dart:io';
import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

class CountingEmbedder implements EmbeddingProvider {
  final HashingEmbedder inner = HashingEmbedder(dim: 64);
  var embedCalls = 0;

  @override
  int get dimension => inner.dimension;

  @override
  String get modelVersion => inner.modelVersion;

  @override
  Float32List embed(String text) {
    embedCalls++;
    return inner.embed(text);
  }
}

ChunkInput chunk(String path, int ord, String text, {String headingPath = ''}) =>
    ChunkInput(
      notePath: path,
      ord: ord,
      headingPath: headingPath,
      text: text,
      hash: '$path:$ord:${text.length}',
    );

void main() {
  test('replaceAll and search return the closest chunk', () async {
    final index = InMemorySemanticIndex(HashingEmbedder(dim: 96));
    await index.replaceAll([
      chunk('a.md', 0, 'resep rendang padang santan daging'),
      chunk('b.md', 0, 'jaringan saraf tiruan deep learning'),
      chunk('c.md', 0, 'cara menanam cabai di polybag'),
    ]);
    final hits = await index.search(HashingEmbedder(dim: 96).embed('resep rendang'));
    expect(hits.first.notePath, 'a.md');
    expect(hits.first.score, greaterThan(0.5));
  });

  test('upsert re-embeds only changed chunks (AI-12)', () async {
    final embedder = CountingEmbedder();
    final index = InMemorySemanticIndex(embedder);
    await index.replaceAll([
      chunk('a.md', 0, 'paragraf pertama'),
      chunk('a.md', 1, 'paragraf kedua'),
      chunk('b.md', 0, 'catatan lain'),
    ]);
    final afterReplace = embedder.embedCalls;

    await index.upsert([
      chunk('a.md', 0, 'paragraf pertama'),
      chunk('a.md', 1, 'paragraf kedua sudah direvisi'),
    ]);
    expect(embedder.embedCalls, afterReplace + 1);

    final hits = await index.search(
      HashingEmbedder(dim: 64).embed('paragraf kedua sudah direvisi'),
    );
    expect(hits.first.notePath, 'a.md');
    expect(hits.first.ord, 1);
  });

  test('removeNotes drops all chunks of a note', () async {
    final index = InMemorySemanticIndex(HashingEmbedder(dim: 64));
    await index.replaceAll([
      chunk('a.md', 0, 'isi satu'),
      chunk('a.md', 1, 'isi dua'),
      chunk('b.md', 0, 'catatan lain'),
    ]);
    await index.removeNotes(['a.md']);
    final hits = await index.search(
      HashingEmbedder(dim: 64).embed('isi satu'),
    );
    expect(hits.where((h) => h.notePath == 'a.md'), isEmpty);
  });

  test('prefilter restricts the scanned subset (AI-30)', () async {
    final index = InMemorySemanticIndex(HashingEmbedder(dim: 64));
    await index.replaceAll([
      chunk('folder/a.md', 0, 'kata kunci burung garuda'),
      chunk('lain/b.md', 0, 'kata kunci burung merpati'),
    ]);
    final hits = await index.search(
      HashingEmbedder(dim: 64).embed('burung'),
      allowedPaths: {'lain/b.md'},
    );
    expect(hits.map((h) => h.notePath), everyElement('lain/b.md'));
  });

  test('persists to JSON and reloads across instances', () async {
    final path = '/tmp/simpul-semantic-test.json';
    final writer = InMemorySemanticIndex(
      HashingEmbedder(dim: 64),
      filePath: path,
    );
    await writer.replaceAll([
      chunk('a.md', 0, 'kata kunci unik pengukuran'),
    ]);
    await writer.close();

    final reader = InMemorySemanticIndex(
      HashingEmbedder(dim: 64),
      filePath: path,
    );
    final hits = await reader.search(
      HashingEmbedder(dim: 64).embed('kata kunci unik pengukuran'),
    );
    expect(hits.first.notePath, 'a.md');
    await reader.close();
  });

  test('stored vectors from a different model version are not mixed (AI-13)', () async {
    final path = '/tmp/simpul-semantic-version.json';
    final writer = InMemorySemanticIndex(
      HashingEmbedder(dim: 64),
      filePath: path,
    );
    await writer.replaceAll([chunk('a.md', 0, 'teks lama')]);
    await writer.close();

    await File(path).writeAsString('{"schema_version":1,"model_version":"model-lain-v9","dim":64,"chunks":[{"path":"a.md","ord":0,"heading_path":"","hash":"x","vec":"_w=="}]}');
    final reader = InMemorySemanticIndex(
      HashingEmbedder(dim: 64),
      filePath: path,
    );
    final hits = await reader.search(HashingEmbedder(dim: 64).embed('teks lama'));
    expect(hits, isEmpty);
    await reader.close();
  });
}
