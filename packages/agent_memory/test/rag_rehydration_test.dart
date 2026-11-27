import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rag_rehydrate');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test(
    'chunk direhidrasi dari FTS pasca-restart dan retrieve tetap hit',
    () async {
      final ftsPath = '${tmp.path}/rag_fts.json';
      final first = RagPipeline(
        dense: BruteForceVectorIndex(),
        lexical: FtsIndex(ftsPath),
      );
      await first.ingest(
        'wiki-vektor',
        'Pencarian vektor membandingkan embedding kueri dengan embedding '
            'dokumen.\n\n'
            'Cosine similarity adalah ukuran kemiripan arah dua vektor.',
      );
      expect(first.chunkCount, greaterThanOrEqualTo(1));

      final reloadedFts = FtsIndex(ftsPath);
      await reloadedFts.load();
      final second = RagPipeline(
        dense: BruteForceVectorIndex(),
        lexical: reloadedFts,
      );
      expect(second.chunkCount, 0);

      final restored = second.restoreChunksFromLexicalIndex();
      expect(restored, greaterThanOrEqualTo(1));
      expect(second.chunkCount, restored);

      final result = await second.retrieve('cosine similarity vektor');
      expect(result.hits, isNotEmpty);
      expect(result.hits.first.chunk.docId, 'wiki-vektor');
      expect(result.context, contains('[1] sumber: wiki-vektor'));
      expect(result.citations.first, contains('wiki-vektor'));
    },
  );

  test('id malformed/legacy dilewati tanpa crash', () async {
    final ftsPath = '${tmp.path}/rag_fts.json';
    final fts = FtsIndex(ftsPath);
    await fts.load();
    fts.upsert('tanpa-hash', 'teks legacy tanpa suffix');
    fts.upsert('doc#', 'suffix kosong');
    fts.upsert('doc#abc', 'suffix bukan angka');
    fts.upsert('doc#-1', 'index negatif');
    await fts.save();

    final reloaded = FtsIndex(ftsPath);
    await reloaded.load();
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: reloaded,
    );
    expect(pipeline.restoreChunksFromLexicalIndex(), 0);
    expect(pipeline.chunkCount, 0);
  });

  test('chunk non-destruktif: chunk existing tidak ditimpa', () async {
    final ftsPath = '${tmp.path}/rag_fts.json';
    final fts = FtsIndex(ftsPath);
    await fts.load();
    fts.upsert('doc#0', 'teks lama di disk');
    await fts.save();

    final pipeline = RagPipeline(dense: BruteForceVectorIndex(), lexical: fts);
    await pipeline.ingest('doc', 'teks baru in-memory');
    final before = pipeline.getChunk('doc#0');

    final restored = pipeline.restoreChunksFromLexicalIndex();
    expect(restored, 0);
    expect(pipeline.getChunk('doc#0')?.text, before?.text);
  });

  test('chunk yang di-remove tidak muncul lagi setelah reload', () async {
    final ftsPath = '${tmp.path}/rag_fts.json';
    final first = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex(ftsPath),
    );
    await first.ingest('doc-a', 'kucing tidur siang di sofa');
    await first.ingest('doc-b', 'anjing bermain bola di taman');
    await first.remove('doc-a');

    final reloaded = FtsIndex(ftsPath);
    await reloaded.load();
    expect(reloaded.documents.keys, isNot(contains('doc-a#0')));

    final second = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: reloaded,
    );
    second.restoreChunksFromLexicalIndex();
    expect(second.getChunk('doc-a#0'), isNull);
    final result = await second.retrieve('kucing sofa');
    expect(result.hits.map((h) => h.chunk.docId), isNot(contains('doc-a')));
  });
}
