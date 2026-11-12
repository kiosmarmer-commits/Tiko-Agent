import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

MemoryHit _hit(
  String id,
  String text, {
  double score = 0.5,
  double confidence = 0.5,
  Provenance provenance = Provenance.unknown,
}) =>
    MemoryHit(
      id: id,
      text: text,
      score: score,
      confidence: confidence,
      provenance: provenance,
    );

void main() {
  const reranker = MemoryReranker();

  test('lexical overlap lifts a matching hit above a baseline', () {
    final hits = [
      _hit('a', 'resep gudeg jogja tradisional', score: 0.9),
      _hit('b', 'nama pengguna adalah Novan', score: 0.5),
    ];
    final out = reranker.rerank('novan', hits);
    expect(out.first.id, 'b');
    expect(out.first.score, greaterThan(out.last.score));
  });

  test('trust and confidence break ties between equal hits', () {
    final hits = [
      _hit('web', 'jakarta adalah ibu kota', score: 0.6, confidence: 0.2,
          provenance: Provenance.web),
      _hit('user', 'jakarta adalah ibu kota', score: 0.6, confidence: 0.9,
          provenance: Provenance.user),
    ];
    final out = reranker.rerank('ibu kota jakarta', hits);
    expect(out.first.id, 'user');
  });

  test('respects the topK cap', () {
    final hits = [
      for (var i = 0; i < 8; i++) _hit('h$i', 'dokumen nomor $i'),
    ];
    expect(reranker.rerank('dokumen', hits, topK: 3).length, 3);
    expect(reranker.rerank('dokumen', hits, topK: 0).length, 0);
  });

  test('empty input returns no hits without throwing', () {
    expect(reranker.rerank('apapun', const <MemoryHit>[]), isEmpty);
  });

  test('ties keep the incoming order', () {
    final hits = [_hit('x', 'alpha beta'), _hit('y', 'alpha beta')];
    final out = reranker.rerank('alpha', hits);
    expect(out.map((h) => h.id).toList(), ['x', 'y']);
  });

  test('scores stay in range and preserve hit fields', () {
    final hit = _hit('keep', 'ingat api key lama', score: 0.9,
        confidence: 0.8, provenance: Provenance.user);
    final out = reranker.rerank('ingat api key', [hit]);
    expect(out.single.score, greaterThanOrEqualTo(0));
    expect(out.single.score, lessThanOrEqualTo(1));
    expect(out.single.score, greaterThan(0.5));
    expect(out.single.id, 'keep');
    expect(out.single.text, 'ingat api key lama');
    expect(out.single.provenance, Provenance.user);
    expect(out.single.confidence, 0.8);
  });
}
