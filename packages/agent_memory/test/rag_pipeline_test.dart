import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  group('RagChunker', () {
    test('splits long text into multiple chunks with ids', () {
      const chunker = RagChunker(targetChars: 100, overlapChars: 20,
          minChars: 10);
      final text = List.generate(10, (i) => 'paragraf $i ${'isi ' * 20}')
          .join('\n\n');
      final chunks = chunker.chunk('doc1', text);
      expect(chunks.length, greaterThan(1));
      expect(chunks.first.id, 'doc1#0');
      expect(chunks[1].id, 'doc1#1');
      expect(chunks[0].index, 0);
      expect(chunks[1].index, 1);
      for (final c in chunks) {
        expect(c.text, isNotEmpty);
        expect(c.docId, 'doc1');
      }
    });

    test('short text stays a single chunk', () {
      const chunker = RagChunker();
      final chunks = chunker.chunk('d', 'teks pendek');
      expect(chunks.length, 1);
      expect(chunks.single.text, 'teks pendek');
    });

    test('empty text produces no chunks', () {
      const chunker = RagChunker();
      expect(chunker.chunk('d', ''), isEmpty);
      expect(chunker.chunk('d', '   \n\n  '), isEmpty);
    });

    test('oversized paragraph is hard-wrapped with overlap', () {
      const chunker = RagChunker(targetChars: 50, overlapChars: 10,
          minChars: 5);
      final word = 'kata';
      final para = List.filled(60, word).join(' ');
      final chunks = chunker.chunk('d', para);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.text.length, lessThanOrEqualTo(70));
      }
    });

    test('json round trip', () {
      const chunker = RagChunker();
      final chunk = chunker.chunk('d', 'halo dunia').single;
      final back = RagChunk.fromJson(chunk.toJson());
      expect(back.id, chunk.id);
      expect(back.text, chunk.text);
    });
  });

  group('QueryExpander', () {
    test('produces original plus keyword variants', () {
      const expander = QueryExpander();
      final variants = expander.expand('Bagaimana cara kerja vektor search?');
      expect(variants.first, 'Bagaimana cara kerja vektor search?');
      expect(variants.length, lessThanOrEqualTo(3));
      expect(variants.any((v) => v.contains('vektor')), isTrue);
    });

    test('single word query does not duplicate variants', () {
      const expander = QueryExpander();
      final variants = expander.expand('vektor');
      expect(variants, ['vektor']);
    });
  });

  group('HybridRetriever', () {
    test('fuses lexical-only retrieval when embedding is empty', () async {
      final lexical = FtsIndex('/tmp/rag_test_fts.json');
      lexical.upsert('c1', 'resep gudeg jogja');
      lexical.upsert('c2', 'jadwal kereta malang surabaya');
      final retriever = HybridRetriever(
        dense: BruteForceVectorIndex(),
        lexical: lexical,
      );
      final fused = await retriever.fuse('resep gudeg', const [], k: 2);
      expect(fused.first.id, 'c1');
      expect(fused, hasLength(2));
    });

    test('dense hits contribute to the fused ranking', () async {
      final dense = BruteForceVectorIndex();
      final lexical = FtsIndex('/tmp/rag_test_fts2.json');
      lexical.upsert('c1', 'resep gudeg jogja');
      lexical.upsert('c2', 'gudeg adalah masakan');
      await dense.upsert('c2', [1.0, 0.0], {});
      await dense.upsert('c1', [0.0, 1.0], {});
      final retriever = HybridRetriever(
        dense: dense,
        lexical: lexical,
      );
      final fused = await retriever.fuse('gudeg', [1.0, 0.0], k: 2);
      expect(fused.first.id, 'c2');
    });
  });

  group('RagPipeline', () {
    RagPipeline pipeline() {
      final dense = BruteForceVectorIndex();
      final lexical = FtsIndex('/tmp/rag_test_pipeline.json');
      return RagPipeline(
        dense: dense,
        lexical: lexical,
        embedder: (text) async {
          final v = List<double>.filled(8, 0);
          for (final t in text.toLowerCase().split(RegExp(r'\W+'))) {
            if (t.isEmpty) continue;
            v[t.hashCode.abs() % 8] += 1;
          }
          return v;
        },
      );
    }

    test('ingest chunks and retrieve with citations', () async {
      final p = pipeline();
      await p.ingest('wiki-vektor', 'Pencarian vektor membandingkan '
          'embedding kueri dengan embedding dokumen.\n\n'
          'Cosine similarity adalah ukuran kemiripan arah dua vektor.');
      await p.ingest('wiki-kucing', 'Kucing adalah hewan mamalia '
          'yang suka tidur siang.');
      expect(p.chunkCount, greaterThanOrEqualTo(2));

      final result = await p.retrieve('cosine similarity vektor');
      expect(result.hits, isNotEmpty);
      expect(result.hits.first.chunk.docId, 'wiki-vektor');
      expect(result.context, contains('[1] sumber: wiki-vektor'));
      expect(result.citations.first, contains('wiki-vektor'));
    });

    test('lexical-only pipeline works without embedder', () async {
      final dense = BruteForceVectorIndex();
      final lexical = FtsIndex('/tmp/rag_test_pipeline2.json');
      final p = RagPipeline(dense: dense, lexical: lexical);
      await p.ingest('doc', 'kucing tidur siang\n\nanjing bermain bola');
      final result = await p.retrieve('anjing');
      expect(result.hits.first.chunk.text, contains('anjing'));
    });

    test('empty query and empty corpus return empty result', () async {
      final p = pipeline();
      expect((await p.retrieve('')).hits, isEmpty);
      expect((await p.retrieve('apa saja')).hits, isEmpty);
    });

    test('remove drops all chunks of a document', () async {
      final p = pipeline();
      await p.ingest('doc-a', 'satu dua\n\ntiga empat');
      await p.ingest('doc-b', 'lima enam');
      final before = await p.retrieve('satu');
      expect(before.hits, isNotEmpty);
      await p.remove('doc-a');
      final after = await p.retrieve('satu');
      expect(after.hits.where((h) => h.chunk.docId == 'doc-a'), isEmpty);
    });

    test('k limits the number of hits', () async {
      final p = pipeline();
      await p.ingest('d', List.generate(6, (i) => 'paragraf $i tentang '
          'kucing').join('\n\n'));
      final result = await p.retrieve('kucing', k: 2);
      expect(result.hits.length, lessThanOrEqualTo(2));
    });
  });
}
