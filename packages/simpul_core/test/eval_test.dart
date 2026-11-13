import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  test('korpus: 42 catatan, 28 kasus, gold path selalu ada di vault', () {
    final notes = EvalCorpus.notes();
    final cases = EvalCorpus.cases();
    final paths = {for (final note in notes) note.path};

    expect(notes, hasLength(42));
    expect(cases, hasLength(28));
    for (final evalCase in cases) {
      expect(evalCase.relevantPaths, isNotEmpty);
      for (final gold in evalCase.relevantPaths) {
        expect(paths, contains(gold));
      }
    }
  });

  test('eval deterministik: dua kali run menghasilkan metrik identik', () {
    final first = EvalHarness.run();
    final second = EvalHarness.run();

    expect(first.toJson(), second.toJson());
    expect(first.modelVersion, 'hashing-v1');
    expect(first.caseCount, 28);
  });

  test('baseline hashing: recall@5 dan MRR di atas ambang kalibrasi', () {
    final result = EvalHarness.run(k: 5);

    expect(result.k, 5);
    expect(result.recallAtK, greaterThanOrEqualTo(0.85),
        reason: 'baseline hashing-v1 terukur 0.893; penurunan berarti regresi');
    expect(result.mrr, greaterThanOrEqualTo(0.75),
        reason: 'baseline hashing-v1 terukur 0.787; penurunan berarti regresi');
  });

  test('recall@1 tidak melebihi MRR untuk kasus single-gold', () {
    final result = EvalHarness.run(k: 1);

    expect(result.k, 1);
    expect(result.mrr, greaterThanOrEqualTo(result.recallAtK));
  });

  test('runAsync menghasilkan metrik identik dengan run untuk embedder sama',
      () async {
    final syncResult = EvalHarness.run();
    final asyncResult = await EvalHarness.runAsync(
      embedder: _SyncAsAsync(),
    );

    expect(asyncResult.toJson(), syncResult.toJson());
  });
}

/// Adapter: HashingEmbedder (sinkron) dibungkus sebagai AsyncEmbeddingProvider
/// untuk memverifikasi jalur runAsync tanpa jaringan.
class _SyncAsAsync implements AsyncEmbeddingProvider {
  final HashingEmbedder _inner = HashingEmbedder();

  @override
  int get dimension => _inner.dimension;

  @override
  String get modelVersion => _inner.modelVersion;

  @override
  Future<Float32List> embed(String text) async => _inner.embed(text);

  @override
  Future<List<Float32List>> embedBatch(List<String> texts) async =>
      [for (final text in texts) _inner.embed(text)];
}
