import 'dart:io';
import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-p6-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/catatan').create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('ReplayEmbedder', () {
    test('menyajikan vektor pre-computed dan fail-closed pada teks asing', () {
      final vector = Float32List.fromList([1.0, 0.0, 0.0]);
      final embedder = ReplayEmbedder(
        modelVersion: 'ollama:test',
        dimension: 3,
        vectors: {'teks': vector},
      );

      expect(embedder.embed('teks'), same(vector));
      expect(embedder.modelVersion, 'ollama:test');
      expect(embedder.dimension, 3);
      expect(() => embedder.embed('tidak ada'), throwsStateError);
    });
  });

  group('InMemorySemanticIndex.storedModelVersion', () {
    test('null saat file tidak ada, versi saat ada', () async {
      final path = '${tmp.path}/vectors.json';
      expect(InMemorySemanticIndex.storedModelVersion(path), isNull);

      final semantic = InMemorySemanticIndex(
        HashingEmbedder(),
        filePath: path,
      );
      await semantic.replaceAll([
        const ChunkInput(
          notePath: 'a.md',
          ord: 0,
          headingPath: '',
          text: 'isi',
          hash: 'h1',
        ),
      ]);
      await semantic.close();

      expect(
        InMemorySemanticIndex.storedModelVersion(path),
        HashingEmbedder().modelVersion,
      );
    });
  });

  group('VaultSync dengan semanticFactory', () {
    test('vektor diperbarui inkremental: hanya chunk berubah di-embed',
        () async {
      await File('$vault/catatan/satu.md').writeAsString('isi awal satu');
      await File('$vault/catatan/dua.md').writeAsString('isi awal dua');

      final index = JsonVaultIndex('$vault/.simpul/index.json');
      await index.replaceAll([]);
      final vectorsPath = '$vault/.simpul/vectors.json';
      final embeddedTexts = <String>{};

      Future<SemanticIndex?> factory(List<ScannedNote> changed) async {
        final replay = ReplayEmbedder(
          modelVersion: HashingEmbedder().modelVersion,
          dimension: 8,
        );
        for (final note in changed) {
          for (final chunk in note.parsed.chunks) {
            replay.put(chunk.text, Float32List(8)..[0] = 1.0);
            embeddedTexts.add(chunk.text);
          }
        }
        return InMemorySemanticIndex(replay, filePath: vectorsPath);
      }

      final first = await VaultSync.apply(index, vault, semanticFactory: factory);
      expect(first.added.length, 2);
      expect(embeddedTexts, {'isi awal satu', 'isi awal dua'});

      embeddedTexts.clear();
      final second =
          await VaultSync.apply(index, vault, semanticFactory: factory);
      expect(second.unchanged, 2);
      expect(embeddedTexts, isEmpty);

      await File('$vault/catatan/satu.md').writeAsString('isi revisi satu');
      await File('$vault/catatan/dua.md').delete();
      embeddedTexts.clear();
      final third =
          await VaultSync.apply(index, vault, semanticFactory: factory);
      expect(third.updated, ['catatan/satu.md']);
      expect(third.removed, ['catatan/dua.md']);
      expect(embeddedTexts, {'isi revisi satu'});

      final semantic = InMemorySemanticIndex(
        HashingEmbedder(),
        filePath: vectorsPath,
      );
      try {
        final hits = await semantic.search(
          HashingEmbedder().embed('isi revisi satu'),
          limit: 10,
        );
        expect(hits.map((h) => h.notePath), ['catatan/satu.md']);
      } finally {
        await semantic.close();
      }
      await index.close();
    });

    test('mismatch model: factory yang mengembalikan null tidak merusak sync',
        () async {
      await File('$vault/catatan/satu.md').writeAsString('isi satu');

      final index = JsonVaultIndex('$vault/.simpul/index.json');
      await index.replaceAll([]);
      final result = await VaultSync.apply(
        index,
        vault,
        semanticFactory: (changed) async => null,
      );
      expect(result.added, ['catatan/satu.md']);
      await index.close();
    });
  });
}
