import 'memory_reranker.dart';
import 'models.dart';

/// One labeled evaluation case: given a query and candidate hits, which
/// hit should rank first.
class MemoryRankCase {
  const MemoryRankCase({
    required this.query,
    required this.hits,
    required this.expectedTopId,
  });

  final String query;
  final List<MemoryHit> hits;
  final String expectedTopId;
}

/// Outcome of one evaluated case.
class MemoryRankResult {
  const MemoryRankResult({
    required this.caseIndex,
    required this.expectedTopId,
    required this.actualTopId,
    required this.passed,
  });

  final int caseIndex;
  final String expectedTopId;
  final String actualTopId;
  final bool passed;
}

/// Scores a [MemoryReranker] against labeled cases and grid-searches
/// the best weight combination on a coarse 0.05-step simplex grid.
class MemoryRankEvalHarness {
  const MemoryRankEvalHarness({
    required this.cases,
    this.reranker = const MemoryReranker(),
  });

  final List<MemoryRankCase> cases;
  final MemoryReranker reranker;

  List<MemoryRankResult> run() {
    final results = <MemoryRankResult>[];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final ranked = reranker.rerank(c.query, c.hits);
      final top = ranked.isEmpty ? '' : ranked.first.id;
      results.add(MemoryRankResult(
        caseIndex: i,
        expectedTopId: c.expectedTopId,
        actualTopId: top,
        passed: top == c.expectedTopId,
      ));
    }
    return results;
  }

  /// Fraction of cases whose top hit matches the label.
  double accuracy() {
    if (cases.isEmpty) return 0;
    final passed = run().where((r) => r.passed).length;
    return passed / cases.length;
  }

  List<MemoryRankResult> failures() => run().where((r) => !r.passed).toList();

  /// Weight combination, summing to 1, with the highest accuracy.
  ({double retrieval, double lexical, double confidence, double trust})
      bestWeights() {
    var bestAcc = -1.0;
    var best = (retrieval: 0.0, lexical: 0.0, confidence: 0.0, trust: 0.0);
    for (final w in _grid()) {
      final acc = MemoryRankEvalHarness(cases: cases, reranker: w).accuracy();
      if (acc > bestAcc) {
        bestAcc = acc;
        best = (
          retrieval: w.retrievalWeight,
          lexical: w.lexicalWeight,
          confidence: w.confidenceWeight,
          trust: w.trustWeight,
        );
      }
    }
    return best;
  }

  Iterable<MemoryReranker> _grid() sync* {
    for (var r = 0; r <= 20; r++) {
      for (var l = 0; r + l <= 20; l++) {
        for (var c = 0; r + l + c <= 20; c++) {
          final t = 20 - r - l - c;
          yield MemoryReranker(
            retrievalWeight: r / 20,
            lexicalWeight: l / 20,
            confidenceWeight: c / 20,
            trustWeight: t / 20,
          );
        }
      }
    }
  }
}

/// 10 labeled Indonesian retrieval cases for reranker calibration.
/// Nine pass with the default weights; the last case shows that a
/// high retrieval score from an untrusted web duplicate can beat the
/// trusted original, which the grid search then corrects.
const indonesianMemoryRankEval10 = <MemoryRankCase>[
  MemoryRankCase(
    query: 'di mana user tinggal',
    expectedTopId: 'tinggal',
    hits: [
      MemoryHit(
        id: 'tinggal',
        text: 'User tinggal di Jakarta',
        score: 0.9,
        provenance: Provenance.user,
        confidence: 0.9,
      ),
      MemoryHit(
        id: 'kopi',
        text: 'User suka kopi',
        score: 0.95,
        provenance: Provenance.user,
        confidence: 0.95,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'apa warna favorit user',
    expectedTopId: 'warna',
    hits: [
      MemoryHit(
        id: 'warna',
        text: 'Warna favorit user adalah biru',
        score: 0.7,
        provenance: Provenance.user,
        confidence: 0.9,
      ),
      MemoryHit(
        id: 'kucing',
        text: 'User punya dua kucing',
        score: 0.9,
        provenance: Provenance.user,
        confidence: 0.9,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'nomor rekening kantor',
    expectedTopId: 'rek',
    hits: [
      MemoryHit(
        id: 'rek',
        text: 'Rekening kantor adalah 123-456',
        score: 0.8,
        provenance: Provenance.user,
        confidence: 0.9,
      ),
      MemoryHit(
        id: 'kucing2',
        text: 'Kucing user berumur tiga tahun',
        score: 0.95,
        provenance: Provenance.web,
        confidence: 0.95,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'kapan deadline laporan',
    expectedTopId: 'deadline',
    hits: [
      MemoryHit(
        id: 'deadline',
        text: 'Deadline laporan hari Jumat',
        score: 0.75,
        provenance: Provenance.agent,
        confidence: 0.95,
      ),
      MemoryHit(
        id: 'deadline-lama',
        text: 'Deadline laporan hari Jumat',
        score: 0.8,
        provenance: Provenance.agent,
        confidence: 0.4,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'berapa ibu kota Prancis',
    expectedTopId: 'paris',
    hits: [
      MemoryHit(
        id: 'paris',
        text: 'Ibu kota Prancis adalah Paris',
        score: 0.85,
        provenance: Provenance.agent,
        confidence: 0.95,
      ),
      MemoryHit(
        id: 'tokyo',
        text: 'Ibu kota Jepang adalah Tokyo',
        score: 0.9,
        provenance: Provenance.user,
        confidence: 0.95,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'resep rendang',
    expectedTopId: 'rendang',
    hits: [
      MemoryHit(
        id: 'rendang',
        text: 'Rendang dibuat dari daging sapi',
        score: 0.6,
        provenance: Provenance.agent,
        confidence: 0.9,
      ),
      MemoryHit(
        id: 'flutter',
        text: 'Panduan instalasi flutter web',
        score: 0.9,
        provenance: Provenance.agent,
        confidence: 0.5,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'siapa nama anjing user',
    expectedTopId: 'bibo',
    hits: [
      MemoryHit(
        id: 'bibo',
        text: 'Anjing user bernama Bibo',
        score: 0.8,
        provenance: Provenance.agent,
        confidence: 0.8,
      ),
      MemoryHit(
        id: 'tinggal2',
        text: 'User tinggal di Jakarta',
        score: 0.8,
        provenance: Provenance.agent,
        confidence: 0.8,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'jam berapa istirahat',
    expectedTopId: 'istirahat',
    hits: [
      MemoryHit(
        id: 'istirahat',
        text: 'Istirahat jam 13:00',
        score: 0.7,
        provenance: Provenance.user,
        confidence: 0.7,
      ),
      MemoryHit(
        id: 'istirahat-web',
        text: 'Istirahat jam 13:00',
        score: 0.7,
        provenance: Provenance.web,
        confidence: 0.7,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'berapa usia kucing user',
    expectedTopId: 'usia',
    hits: [
      MemoryHit(
        id: 'usia',
        text: 'Kucing user berumur tiga tahun',
        score: 0.9,
        provenance: Provenance.user,
        confidence: 0.9,
      ),
      MemoryHit(
        id: 'kucing3',
        text: 'Kucing user suka makan ikan',
        score: 0.85,
        provenance: Provenance.agent,
        confidence: 0.9,
      ),
    ],
  ),
  MemoryRankCase(
    query: 'kata sandi wifi kantor',
    expectedTopId: 'sandi',
    hits: [
      MemoryHit(
        id: 'sandi',
        text: 'Kata sandi wifi kantor: tiko-2026',
        score: 0.5,
        provenance: Provenance.user,
        confidence: 0.6,
      ),
      MemoryHit(
        id: 'sandi-web',
        text: 'Kata sandi wifi kantor: tiko-2026',
        score: 0.95,
        provenance: Provenance.web,
        confidence: 0.95,
      ),
    ],
  ),
];
