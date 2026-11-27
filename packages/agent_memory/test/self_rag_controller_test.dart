import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  const gate = SelfRagController();

  RagHit hit(String docId, String text, {double score = 3.2, int rank = 0}) =>
      RagHit(
        chunk: RagChunk(id: '$docId#0', docId: docId, text: text, index: 0),
        score: score,
        rank: rank,
      );

  test('query kosong ditolak', () {
    final a = gate.assess(query: '   ', hits: const [], context: '');
    expect(a.accepted, isFalse);
    expect(a.reason, contains('kosong'));
  });

  test('query melebihi batas panjang ditolak', () {
    final a = gate.assess(
      query: 'kucing' * 300,
      hits: [hit('d', 'kucing tidur')],
      context: 'kucing tidur',
    );
    expect(a.accepted, isFalse);
    expect(a.reason, contains('karakter'));
  });

  test('tanpa hasil retrieval ditolak', () {
    final a = gate.assess(query: 'kucing tidur', hits: const [], context: '');
    expect(a.accepted, isFalse);
    expect(a.reason, contains('retrieval'));
  });

  test('lexical: konteks relevan diterima', () {
    const context = 'Kucing adalah hewan mamalia yang suka tidur siang.';
    final a = gate.assess(
      query: 'kucing tidur siang',
      hits: [hit('wiki-kucing', context)],
      context: context,
    );
    expect(a.accepted, isTrue);
    expect(a.coverage, 1);
    expect(a.matchedTerms, containsAll(['kucing', 'tidur', 'siang']));
    expect(a.hitCount, 1);
    expect(a.citations.first, contains('wiki-kucing'));
  });

  test('lexical: false positive BM25 coverage rendah ditolak', () {
    const context = 'Anjing bermain bola di taman kota.';
    final a = gate.assess(
      query: 'kucing tidur siang di sofa',
      hits: [hit('wiki-anjing', context)],
      context: context,
    );
    expect(a.accepted, isFalse);
    expect(a.coverage, lessThan(gate.minCoverage));
  });

  test('lexical: coverage tepat di ambang diterima', () {
    const controller = SelfRagController(minCoverage: 0.5);
    const context = 'Kucing tidur. Anjing bermain bola di taman kota.';
    final a = controller.assess(
      query: 'kucing tidur santai',
      hits: [hit('d', context)],
      context: context,
    );
    expect(a.coverage, closeTo(2 / 3, 1e-9));
    expect(a.accepted, isTrue);
  });

  test('embedder terkonfigurasi: paraphrase skor tinggi diterima', () {
    const context =
        'Feline mamalia ini menghabiskan waktu rehat di siang hari.';
    final a = gate.assess(
      query: 'kucing suka tidur siang',
      hits: [hit('wiki-kucing', context, score: 0.82)],
      context: context,
      embedderConfigured: true,
    );
    expect(a.accepted, isTrue);
    expect(a.reason, contains('semantic'));
  });

  test('embedder terkonfigurasi: skor non-finite atau nol ditolak', () {
    const context = 'Kucing tidur siang.';
    for (final score in [0.0, double.nan, double.negativeInfinity]) {
      final a = gate.assess(
        query: 'kucing tidur siang',
        hits: [hit('d', context, score: score)],
        context: context,
        embedderConfigured: true,
      );
      expect(a.accepted, isFalse, reason: 'score=$score');
    }
  });

  test('embedder terkonfigurasi: skor positif tetap menang atas coverage', () {
    const context = 'Anjing bermain bola di taman kota.';
    final a = gate.assess(
      query: 'kucing tidur siang di sofa',
      hits: [hit('wiki-anjing', context, score: 0.9)],
      context: context,
      embedderConfigured: true,
    );
    expect(a.accepted, isTrue);
  });

  test('query tanpa kata isi tidak bisa dinilai', () {
    final a = gate.assess(
      query: 'apa itu ???',
      hits: [hit('d', 'kucing tidur')],
      context: 'kucing tidur',
    );
    expect(a.accepted, isFalse);
    expect(a.reason, contains('kata isi'));
  });

  test('toJson serializable dan konsisten dengan accepted', () {
    const context = 'Kucing tidur siang.';
    final a = gate.assess(
      query: 'kucing tidur',
      hits: [hit('d', context)],
      context: context,
    );
    final json = a.toJson();
    expect(json['status'], a.status);
    expect(json['coverage'], a.coverage);
    expect(json['query_terms'], a.queryTerms);
    expect(json['matched_terms'], a.matchedTerms);
    expect(json['hit_count'], a.hitCount);
    expect(json['citations'], a.citations);
    expect(a.accepted, a.status == 'accepted');
  });
}
