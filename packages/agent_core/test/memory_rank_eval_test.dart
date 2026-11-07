import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('akurasi bobot default minimal 0.8', () {
    final harness = MemoryRankEvalHarness(cases: indonesianMemoryRankEval10);
    expect(harness.accuracy(), greaterThanOrEqualTo(0.8));
  });

  test('satu kasus gagal: duplikat web mengalahkan sumber tepercaya', () {
    final harness = MemoryRankEvalHarness(cases: indonesianMemoryRankEval10);
    final failures = harness.failures();
    expect(failures, hasLength(1));
    expect(failures.single.caseIndex, 9);
    expect(failures.single.expectedTopId, 'sandi');
    expect(failures.single.actualTopId, 'sandi-web');
  });

  test('grid-search menemukan bobot dengan akurasi maksimal', () {
    final harness = MemoryRankEvalHarness(cases: indonesianMemoryRankEval10);
    final w = harness.bestWeights();
    final tuned = MemoryReranker(
      retrievalWeight: w.retrieval,
      lexicalWeight: w.lexical,
      confidenceWeight: w.confidence,
      trustWeight: w.trust,
    );
    final tunedAcc = MemoryRankEvalHarness(
      cases: indonesianMemoryRankEval10,
      reranker: tuned,
    ).accuracy();
    expect(tunedAcc, greaterThanOrEqualTo(harness.accuracy()));
    expect(tunedAcc, 1.0);
  });
}
