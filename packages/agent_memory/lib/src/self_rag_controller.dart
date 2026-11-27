import 'rag_pipeline.dart';

/// Self-RAG-inspired evidence gate (ICLR 2024, deterministik — BUKAN
/// replikasi penuh): sebelum konteks RAG disuntikkan ke system prompt,
/// nilai apakah hasil retrieval benar-benar relevan dengan query.
///
/// Kebijakan (audit 2026-11-28 §8.2):
/// - query kosong atau melebihi [maxQueryChars] → ditolak;
/// - tidak ada hit/konteks → ditolak;
/// - lexical-only → hitung coverage `matched unique content terms /
///   query unique content terms`; diterima bila >= [minCoverage];
/// - embedder terkonfigurasi → diterima bila skor hybrid terbaik finite
///   dan positif, agar paraphrase tidak ditolak hanya karena overlap
///   token rendah;
/// - konteks lemah (false positive BM25) tidak pernah masuk prompt.
///
/// Keterbatasan sadar: `embedder != null` hanya berarti embedder
/// terkonfigurasi, bukan bukti embedding sukses per-request (RagPipeline
/// bisa fallback lexical). Metadata "vector path actually used" menyusul
/// bersama rehidrasi `_chunkVectors` (RAG-02).
class SelfRagAssessment {
  const SelfRagAssessment({
    required this.status,
    required this.reason,
    this.coverage = 0,
    this.matchedTerms = const [],
    this.queryTerms = const [],
    this.hitCount = 0,
    this.citations = const [],
  });

  /// `accepted` atau `rejected`.
  final String status;
  final String reason;
  final double coverage;
  final List<String> matchedTerms;
  final List<String> queryTerms;
  final int hitCount;
  final List<String> citations;

  bool get accepted => status == 'accepted';

  Map<String, dynamic> toJson() => {
    'status': status,
    'reason': reason,
    'coverage': coverage,
    'matched_terms': matchedTerms,
    'query_terms': queryTerms,
    'hit_count': hitCount,
    'citations': citations,
  };
}

class SelfRagController {
  const SelfRagController({this.minCoverage = 0.25, this.maxQueryChars = 1000})
    : assert(minCoverage >= 0 && minCoverage <= 1),
      assert(maxQueryChars > 0);

  /// Ambang coverage lexical untuk mode tanpa embedder.
  final double minCoverage;

  /// Query lebih panjang dari ini dianggap bukan query knowledge (ditolak).
  final int maxQueryChars;

  /// Kata isi: token >= 3 char di luar stopword (konsisten dengan pola
  /// [QueryExpander]); token pendek/stopword terlalu generik untuk menilai
  /// relevansi.
  static const _stopwords = {
    'yang',
    'di',
    'ke',
    'dari',
    'untuk',
    'dan',
    'atau',
    'the',
    'a',
    'an',
    'of',
    'to',
    'and',
    'or',
    'is',
    'are',
    'in',
    'on',
    'apa',
    'bagaimana',
    'itu',
    'dengan',
    'pada',
    'adalah',
    'was',
    'were',
    'for',
    'by',
    'as',
    'at',
    'be',
    'this',
    'that',
    'not',
    'juga',
    'akan',
    'tidak',
    'bisa',
  };

  SelfRagAssessment assess({
    required String query,
    required List<RagHit> hits,
    required String context,
    bool embedderConfigured = false,
  }) {
    final q = query.trim();
    if (q.isEmpty) {
      return const SelfRagAssessment(
        status: 'rejected',
        reason: 'query kosong',
      );
    }
    if (q.length > maxQueryChars) {
      return SelfRagAssessment(
        status: 'rejected',
        reason: 'query melebihi $maxQueryChars karakter',
      );
    }
    if (hits.isEmpty || context.trim().isEmpty) {
      return const SelfRagAssessment(
        status: 'rejected',
        reason: 'tidak ada hasil retrieval',
      );
    }
    final citations = hits
        .map((h) => '${h.rank + 1}. ${h.chunk.docId}')
        .toList();
    final queryTerms = _contentTerms(q);
    if (queryTerms.isEmpty) {
      return SelfRagAssessment(
        status: 'rejected',
        reason: 'query tanpa kata isi yang bisa dinilai',
        hitCount: hits.length,
        citations: citations,
      );
    }
    final corpus = context.toLowerCase();
    final matched = queryTerms.where(corpus.contains).toList();
    final coverage = matched.length / queryTerms.length;
    if (embedderConfigured) {
      var best = double.negativeInfinity;
      for (final h in hits) {
        if (h.score.isFinite && h.score > best) best = h.score;
      }
      if (best.isFinite && best > 0) {
        return SelfRagAssessment(
          status: 'accepted',
          reason: 'semantic: skor hybrid terbaik $best',
          coverage: coverage,
          matchedTerms: matched,
          queryTerms: queryTerms,
          hitCount: hits.length,
          citations: citations,
        );
      }
      return SelfRagAssessment(
        status: 'rejected',
        reason: 'skor hybrid terbaik tidak finite/positif',
        coverage: coverage,
        matchedTerms: matched,
        queryTerms: queryTerms,
        hitCount: hits.length,
        citations: citations,
      );
    }
    if (coverage >= minCoverage) {
      return SelfRagAssessment(
        status: 'accepted',
        reason:
            'lexical: coverage ${coverage.toStringAsFixed(2)} >= $minCoverage',
        coverage: coverage,
        matchedTerms: matched,
        queryTerms: queryTerms,
        hitCount: hits.length,
        citations: citations,
      );
    }
    return SelfRagAssessment(
      status: 'rejected',
      reason: 'lexical: coverage ${coverage.toStringAsFixed(2)} < $minCoverage',
      coverage: coverage,
      matchedTerms: matched,
      queryTerms: queryTerms,
      hitCount: hits.length,
      citations: citations,
    );
  }

  static List<String> _contentTerms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length >= 3 && !_stopwords.contains(t))
      .toSet()
      .toList();
}
