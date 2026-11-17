import 'dart:async';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

/// Embedder fake: delay + lacak konkurensi puncak.
class _TrackingEmbedder {
  _TrackingEmbedder(this.delay);

  final Duration delay;
  int _active = 0;
  int maxConcurrent = 0;
  int calls = 0;

  Future<List<double>> embed(String text) async {
    calls++;
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
    try {
      await Future<void>.delayed(delay);
      // Vektor deterministik dari panjang+hash teks agar ranking stabil.
      final seed = text.hashCode;
      return List.generate(8, (i) => ((seed >> i) & 1).toDouble());
    } finally {
      _active--;
    }
  }
}

RagPipeline _pipeline(
  _TrackingEmbedder embedder, {
  int maxConcurrency = 4,
  RagChunker chunker = const RagChunker(),
}) {
  return RagPipeline(
    dense: BruteForceVectorIndex(),
    lexical: FtsIndex('/tmp/rag_conc_test_fts.json'),
    embedder: embedder.embed,
    maxConcurrency: maxConcurrency,
    chunker: chunker,
  );
}

void main() {
  group('RagPipeline fan-out paralel terbatas (D4)', () {
    test('ingest: embedding konkuren, urutan chunk terjaga', () async {
      final embedder = _TrackingEmbedder(const Duration(milliseconds: 5));
      final rag = _pipeline(
        embedder,
        maxConcurrency: 4,
        // Chunker kecil agar 12 paragraf pendek = 12 chunk terpisah.
        chunker: const RagChunker(
          targetChars: 60,
          overlapChars: 10,
          minChars: 10,
        ),
      );
      final text = List.generate(
              12,
              (i) => 'paragraf nomor $i tentang kunci mobil di parkiran')
          .join('\n\n');
      final chunks = await rag.ingest('doc1', text);
      expect(chunks.length, 12);
      expect(embedder.calls, 12);
      // Paralel terjadi (lebih dari 1 bersamaan)...
      expect(embedder.maxConcurrent, greaterThan(1));
      // ...tapi tidak melewati batas.
      expect(embedder.maxConcurrent, lessThanOrEqualTo(4));
      // Urutan chunk tetap benar (index 0..n-1).
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].index, i);
      }
    });

    test('retrieve: variant konkuren terbatas, hasil deterministik', () async {
      final embedder = _TrackingEmbedder(const Duration(milliseconds: 5));
      final rag = _pipeline(embedder, maxConcurrency: 3);
      await rag.ingest(
        'doc1',
        [
          'kunci mobil ada di atas meja kayu',
          'resep masakan pedas ala restoran',
          'laporan keuangan kuartal tiga perusahaan',
        ].join('\n\n'),
      );
      final r1 = await rag.retrieve('kunci mobil di meja', k: 3);
      final r2 = await rag.retrieve('kunci mobil di meja', k: 3);
      // Deterministik: dua retrieve sama → urutan sama.
      expect(
        r1.hits.map((h) => h.chunk.id).toList(),
        r2.hits.map((h) => h.chunk.id).toList(),
      );
      expect(r1.hits, isNotEmpty);
      expect(embedder.maxConcurrent, lessThanOrEqualTo(3));
    });

    test('hasil paralel identik dengan sekuensial (maxConcurrency 1)',
        () async {
      const text = 'kunci mobil ada di atas meja kayu\n\n'
          'resep masakan pedas ala restoran\n\n'
          'laporan keuangan kuartal tiga perusahaan\n\n'
          'jadwal latihan sepak bola anak';

      final embedderSeq = _TrackingEmbedder(Duration.zero);
      final seq = _pipeline(embedderSeq, maxConcurrency: 1);
      await seq.ingest('doc1', text);
      final seqResult = await seq.retrieve('kunci mobil di meja', k: 4);

      final embedderPar = _TrackingEmbedder(Duration.zero);
      final par = _pipeline(embedderPar, maxConcurrency: 4);
      await par.ingest('doc1', text);
      final parResult = await par.retrieve('kunci mobil di meja', k: 4);

      expect(
        parResult.hits.map((h) => (id: h.chunk.id, score: h.score)).toList(),
        seqResult.hits.map((h) => (id: h.chunk.id, score: h.score)).toList(),
        reason: 'fan-out paralel tidak boleh mengubah ranking/skor',
      );
    });

    test('retrieve paralel lebih cepat dari sekuensial (I/O-bound)', () async {
      const delay = Duration(milliseconds: 30);
      final seq = _pipeline(_TrackingEmbedder(delay), maxConcurrency: 1);
      final par = _pipeline(_TrackingEmbedder(delay), maxConcurrency: 4);
      const doc = 'laporan keuangan kuartal perusahaan teknologi nasional '
          'menunjukkan pertumbuhan\n\n'
          'data pendapatan kuartal perusahaan teknologi nasional meningkat';
      await seq.ingest('doc1', doc);
      await par.ingest('doc1', doc);

      const query = 'laporan keuangan kuartal perusahaan teknologi nasional';
      final swSeq = Stopwatch()..start();
      await seq.retrieve(query, k: 2);
      swSeq.stop();

      final swPar = Stopwatch()..start();
      await par.retrieve(query, k: 2);
      swPar.stop();

      // Retrieve punya >= 2 variant (query + keyword); paralel harus jelas
      // lebih cepat. Toleransi longgar untuk CI lambat.
      expect(swPar.elapsedMilliseconds,
          lessThan(swSeq.elapsedMilliseconds));
    });

    test('embedder null: ingest & retrieve tetap jalan (lexical only)',
        () async {
      final rag = RagPipeline(
        dense: BruteForceVectorIndex(),
        lexical: FtsIndex('/tmp/rag_conc_test_fts.json'),
        maxConcurrency: 4,
      );
      await rag.ingest('doc1', 'kunci mobil di atas meja kayu');
      final result = await rag.retrieve('kunci mobil', k: 3);
      expect(result.hits, isNotEmpty);
    });

    test('maxConcurrency 1 = sekuensial penuh', () async {
      final embedder = _TrackingEmbedder(const Duration(milliseconds: 3));
      final rag = _pipeline(embedder, maxConcurrency: 1);
      await rag.ingest('doc1', 'a\n\nb\n\nc\n\nd');
      expect(embedder.maxConcurrent, 1);
    });

    test('assert: maxConcurrency di luar 1..16 ditolak', () {
      expect(
        () => RagPipeline(
          dense: BruteForceVectorIndex(),
          lexical: FtsIndex('/tmp/rag_conc_test_fts.json'),
          maxConcurrency: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => RagPipeline(
          dense: BruteForceVectorIndex(),
          lexical: FtsIndex('/tmp/rag_conc_test_fts.json'),
          maxConcurrency: 17,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
