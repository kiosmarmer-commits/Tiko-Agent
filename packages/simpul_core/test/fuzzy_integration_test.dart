import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('fuzzy search integration (FR-33)', () {
    test('JsonVaultIndex rescues typo terms', () async {
      final dir = await Directory.systemTemp.createTemp('simpul_fuzzy_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final index = JsonVaultIndex('${dir.path}/index.json');
      await index.replaceAll(const [
        IndexedNote(
          path: 'ai.md',
          title: 'Embedding Vektor',
          mtimeNs: 0,
          sizeBytes: 0,
          contentHash: 'hash-ai.md',
          wordCount: 6,
          props: {},
          tags: [],
          aliases: [],
          links: [],

          chunks: [
            NoteChunk(
              headingPath: 'Embedding Vektor',
              startChar: 0,
              endChar: 41,
              text: 'Embedding vektor untuk pencarian semantik',
            ),
          ],
        ),
      ]);
      final exact = await index.search('embedding');
      expect(exact, isNotEmpty);
      final typo = await index.search('embeding');
      expect(typo, isNotEmpty);
      expect(typo.first.path, 'ai.md');
      await index.close();
    });

    test('unrelated terms produce no hits', () async {
      final dir = await Directory.systemTemp.createTemp('simpul_fuzzy2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final index = JsonVaultIndex('${dir.path}/index.json');
      await index.replaceAll(const [
        IndexedNote(
          path: 'jaringan.md',
          title: 'Jaringan Saraf',
          mtimeNs: 0,
          sizeBytes: 0,
          contentHash: 'hash-jaringan.md',
          wordCount: 4,
          props: {},
          tags: [],
          aliases: [],
          links: [],

          chunks: [
            NoteChunk(
              headingPath: '',
              startChar: 0,
              endChar: 14,
              text: 'Jaringan saraf biologis',
            ),
          ],
        ),
      ]);
      final miss = await index.search('komputer');
      expect(miss, isEmpty);
      final hit = await index.search('jaringan');
      expect(hit, isNotEmpty);
      await index.close();
    });
  });
}
