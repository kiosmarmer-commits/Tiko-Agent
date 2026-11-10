import 'models.dart';

/// Re-ranks memory retrieval hits (PRD 9.1) by blending the original
/// retrieval score with lexical query overlap, stored confidence and
/// provenance trust. Pure and deterministic so tests can assert results.
class MemoryReranker {
  const MemoryReranker({
    this.retrievalWeight = 0.55,
    this.lexicalWeight = 0.25,
    this.confidenceWeight = 0.15,
    this.trustWeight = 0.05,
  });

  final double retrievalWeight;
  final double lexicalWeight;
  final double confidenceWeight;
  final double trustWeight;

  /// Trusted provenances rank highest; web-sourced facts rank lowest.
  double trustScore(Provenance provenance) => switch (provenance) {
        Provenance.user || Provenance.trustedConfig => 1.0,
        Provenance.agent || Provenance.memory => 0.8,
        Provenance.localFile || Provenance.email => 0.6,
        Provenance.mcp => 0.5,
        Provenance.web => 0.4,
        Provenance.unknown => 0.3,
      };

  static Set<String> tokenize(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty)
      .toSet();

  /// Fraction of query tokens that also appear in [text]; zero when
  /// either side has no usable tokens.
  double lexicalOverlap(String query, String text) {
    final queryTokens = tokenize(query);
    if (queryTokens.isEmpty) return 0;
    final textTokens = tokenize(text);
    if (textTokens.isEmpty) return 0;
    final overlap =
        queryTokens.where((t) => textTokens.contains(t)).length;
    return overlap / queryTokens.length;
  }

  /// Combined 0..1 relevance of [hit] for [query].
  double score(String query, MemoryHit hit) {
    final weightSum =
        retrievalWeight + lexicalWeight + confidenceWeight + trustWeight;
    if (weightSum <= 0) return hit.score.clamp(0.0, 1.0).toDouble();
    final combined = retrievalWeight * hit.score.clamp(0.0, 1.0) +
        lexicalWeight * lexicalOverlap(query, hit.text) +
        confidenceWeight * hit.confidence.clamp(0.0, 1.0) +
        trustWeight * trustScore(hit.provenance);
    return (combined / weightSum).clamp(0.0, 1.0).toDouble();
  }

  /// Stable re-rank: returns up to [topK] hits (all when null), best
  /// first, with [MemoryHit.score] replaced by the combined score. Ties
  /// keep the incoming order.
  List<MemoryHit> rerank(String query, List<MemoryHit> hits, {int? topK}) {
    if (hits.isEmpty) return const <MemoryHit>[];
    final scored = <_ScoredHit>[
      for (var i = 0; i < hits.length; i++)
        _ScoredHit(score(query, hits[i]), i, hits[i]),
    ];
    scored.sort((a, b) {
      final byScore = b.combined.compareTo(a.combined);
      if (byScore != 0) return byScore;
      return a.index.compareTo(b.index);
    });
    var limit = topK ?? scored.length;
    if (limit < 0) limit = 0;
    if (limit > scored.length) limit = scored.length;
    return [
      for (final entry in scored.take(limit))
        MemoryHit(
          id: entry.hit.id,
          text: entry.hit.text,
          score: entry.combined,
          provenance: entry.hit.provenance,
          confidence: entry.hit.confidence,
          state: entry.hit.state,
          ttlDays: entry.hit.ttlDays,
          ownerKey: entry.hit.ownerKey,
          createdAt: entry.hit.createdAt,
        ),
    ];
  }
}

class _ScoredHit {
  const _ScoredHit(this.combined, this.index, this.hit);

  final double combined;
  final int index;
  final MemoryHit hit;
}
