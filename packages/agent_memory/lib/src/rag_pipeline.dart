import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';

import 'fts_index.dart';

import 'vector_index.dart';

/// Advanced RAG pipeline: chunking → dual retrieval (dense + BM25) →
/// Reciprocal Rank Fusion → lexical rerank → cited context assembly.
///
/// All stages are deterministic so tests and golden evaluations can assert
/// exact outputs. The embedder is injected by the host; a null embedder
/// degrades the pipeline to lexical-only retrieval.

/// One retrievable piece of a document.
class RagChunk {
  const RagChunk({
    required this.id,
    required this.docId,
    required this.text,
    required this.index,
    this.meta = const {},
  });

  final String id;
  final String docId;
  final String text;

  /// Chunk position within its document, 0-based.
  final int index;
  final Map<String, Object?> meta;

  Map<String, dynamic> toJson() => {
        'id': id,
        'doc_id': docId,
        'text': text,
        'index': index,
        'meta': meta,
      };

  factory RagChunk.fromJson(Map<String, dynamic> json) => RagChunk(
        id: json['id'] as String? ?? '',
        docId: json['doc_id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        index: json['index'] as int? ?? 0,
        meta: json['meta'] is Map
            ? Map<String, Object?>.from(json['meta'] as Map)
            : const {},
      );
}

/// Paragraph-aware recursive chunker with overlap. Splits on blank lines
/// first, then hard-wraps oversized paragraphs while keeping [overlapChars]
/// of trailing context so answers that span a boundary stay retrievable.
class RagChunker {
  const RagChunker({
    this.targetChars = 800,
    this.overlapChars = 120,
    this.minChars = 40,
  });

  final int targetChars;
  final int overlapChars;
  final int minChars;

  List<RagChunk> chunk(
    String docId,
    String text, {
    Map<String, Object?> meta = const {},
  }) {
    final pieces = <String>[];
    final paragraphs = text
        .split(RegExp(r'\n\s*\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    var buffer = '';
    for (final para in paragraphs) {
      if (para.length > targetChars) {
        if (buffer.length >= minChars) {
          pieces.add(buffer.trim());
          buffer = '';
        }
        var cursor = 0;
        final step = math.max(1, targetChars - overlapChars);
        while (cursor < para.length) {
          var end = math.min(cursor + targetChars, para.length);
          if (end < para.length) {
            final boundary = para.lastIndexOf(' ', end);
            if (boundary > cursor + minChars) end = boundary;
          }
          pieces.add(para.substring(cursor, end).trim());
          if (end >= para.length) break;
          cursor = math.max(cursor + step, end - overlapChars);
        }
        continue;
      }
      if (buffer.isNotEmpty &&
          buffer.length + para.length + 2 > targetChars) {
        pieces.add(buffer.trim());
        buffer = '';
      }
      buffer = buffer.isEmpty ? para : '$buffer\n\n$para';
    }
    if (buffer.trim().length >= minChars || pieces.isEmpty) {
      final last = buffer.trim();
      if (last.isNotEmpty) pieces.add(last);
    } else if (buffer.trim().isNotEmpty) {
      final prev = pieces.removeLast();
      pieces.add('$prev\n\n${buffer.trim()}');
    }
    final chunks = <RagChunk>[];
    for (var i = 0; i < pieces.length; i++) {
      chunks.add(RagChunk(
        id: '$docId#$i',
        docId: docId,
        text: pieces[i],
        index: i,
        meta: meta,
      ));
    }
    return chunks;
  }
}

/// Deterministic query expansion: the original query plus a keyword variant
/// (top distinct content words, longest first) and a compact variant with
/// stopwords removed. Helps BM25 recall without an LLM round-trip.
class QueryExpander {
  const QueryExpander({this.maxVariants = 3});

  final int maxVariants;

  static const _stopwords = {
    'yang', 'di', 'ke', 'dari', 'untuk', 'dan', 'atau', 'the', 'a', 'an',
    'of', 'to', 'and', 'or', 'is', 'are', 'in', 'on', 'apa', 'bagaimana',
  };

  List<String> expand(String query) {
    final variants = <String>[query.trim()];
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !_stopwords.contains(w))
        .toSet()
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final keywordVariant = words.join(' ');
    if (keywordVariant.isNotEmpty &&
        !variants.contains(keywordVariant) &&
        variants.length < maxVariants) {
      variants.add(keywordVariant);
    }
    final keywords = words.take(4).join(' ');
    if (keywords.isNotEmpty &&
        keywords != variants.last &&
        variants.length < maxVariants) {
      variants.add(keywords);
    }
    return variants.take(maxVariants).toList();
  }
}

/// A fused retrieval hit.
class RagHit {
  const RagHit({required this.chunk, required this.score, required this.rank});

  final RagChunk chunk;
  final double score;
  final int rank;
}

/// Retrieval output with a cited context block ready for the prompt.
class RagResult {
  const RagResult({required this.hits, required this.context});

  final List<RagHit> hits;

  /// Assembled context with `[n] source` markers matching [citations].
  final String context;

  List<String> get citations =>
      hits.map((h) => '${h.rank + 1}. ${h.chunk.docId}').toList();
}

/// Embedding callback injected by the host (provider `embed`).
typedef RagEmbedder = Future<List<double>> Function(String text);

/// Fuses dense and lexical rankings with Reciprocal Rank Fusion:
/// `score(d) = Σ weight_i / (rrfK + rank_i(d))`. RRF is rank-based so it is
/// robust to incompatible score scales between BM25 and cosine similarity.
class HybridRetriever {
  HybridRetriever({
    required this.dense,
    required this.lexical,
    this.rrfK = 60,
    this.denseWeight = 1.0,
    this.lexicalWeight = 1.0,
  });

  final VectorIndex dense;
  final FtsIndex lexical;
  final int rrfK;
  final double denseWeight;
  final double lexicalWeight;

  /// Returns fused score per chunk id, best first, limited to [k].
  Future<List<({String id, double score})>> fuse(
    String query,
    List<double> queryEmbedding, {
    int k = 8,
  }) async {
    final scores = <String, double>{};
    final bestDenseRank = <String, int>{};
    var denseHitCount = 0;
    if (queryEmbedding.isNotEmpty) {
      final hits = await dense.topK(queryEmbedding, k);
      denseHitCount = hits.length;
      for (var i = 0; i < hits.length; i++) {
        final id = hits[i].id;
        scores[id] = (scores[id] ?? 0) + denseWeight / (rrfK + i + 1);
        bestDenseRank[id] = i;
      }
    }
    final lexicalHits = lexical.search(query, k: k);
    for (var i = 0; i < lexicalHits.length; i++) {
      final hit = lexicalHits[i];
      scores[hit.id] = (scores[hit.id] ?? 0) + lexicalWeight / (rrfK + i + 1);
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        if (byScore != 0) return byScore;
        final denseA = bestDenseRank[a.key] ?? denseHitCount;
        final denseB = bestDenseRank[b.key] ?? denseHitCount;
        if (denseA != denseB) return denseA.compareTo(denseB);
        return a.key.compareTo(b.key);
      });
    return ranked.take(k).map((e) => (id: e.key, score: e.value)).toList();
  }
}

/// End-to-end retrieval-augmented generation pipeline.
class RagPipeline {
  RagPipeline({
    required this.dense,
    required this.lexical,
    this.embedder,
    this.chunker = const RagChunker(),
    this.expander = const QueryExpander(),
  });

  final VectorIndex dense;
  final FtsIndex lexical;
  final RagEmbedder? embedder;
  final RagChunker chunker;
  final QueryExpander expander;

  final Map<String, RagChunk> _chunks = {};

  int get chunkCount => _chunks.length;

  RagChunk? getChunk(String id) => _chunks[id];

  /// Chunks [text], indexes each chunk in both the vector index (when an
  /// embedder is available) and the lexical index. Returns the chunks.
  Future<List<RagChunk>> ingest(
    String docId,
    String text, {
    Map<String, Object?> meta = const {},
  }) async {
    final chunks = chunker.chunk(docId, text, meta: meta);
    for (final chunk in chunks) {
      _chunks[chunk.id] = chunk;
      lexical.upsert(chunk.id, chunk.text);
      final embed = embedder;
      if (embed != null) {
        final vector = await embed(chunk.text);
        if (vector.isNotEmpty) {
          await dense.upsert(chunk.id, vector, {
            'doc_id': chunk.docId,
            'index': chunk.index,
          });
        }
      }
    }
    return chunks;
  }

  Future<void> remove(String docId) async {
    final ids = _chunks.values
        .where((c) => c.docId == docId)
        .map((c) => c.id)
        .toList();
    for (final id in ids) {
      _chunks.remove(id);
      lexical.remove(id);
      if (dense is BruteForceVectorIndex) {
        await (dense as BruteForceVectorIndex).remove(id);
      }
    }
  }

  /// Multi-query hybrid retrieval with lexical rerank and cited context
  /// assembly. [k] controls the number of hits returned.
  Future<RagResult> retrieve(
    String query, {
    int k = 6,
    int candidatesPerVariant = 8,
  }) async {
    if (query.trim().isEmpty || _chunks.isEmpty) {
      return const RagResult(hits: [], context: '');
    }
    final variants = expander.expand(query);
    final fused = <String, double>{};
    for (final variant in variants) {
      final embedding = await _safeEmbed(variant);
      final partial = await HybridRetriever(
        dense: dense,
        lexical: lexical,
      ).fuse(variant, embedding, k: candidatesPerVariant);
      for (final hit in partial) {
        fused[hit.id] = (fused[hit.id] ?? 0) + hit.score;
      }
    }
    final ranked = fused.entries.toList()
      ..sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        if (byScore != 0) return byScore;
        return a.key.compareTo(b.key);
      });
    final hits = <RagHit>[];
    for (final entry in ranked.take(k)) {
      final chunk = _chunks[entry.key];
      if (chunk == null) continue;
      final overlap = _lexicalOverlap(query, chunk.text);
      hits.add(RagHit(chunk: chunk, score: entry.value + 0.1 * overlap,
          rank: 0));
    }
    for (var i = 0; i < hits.length; i++) {
      hits[i] = RagHit(chunk: hits[i].chunk, score: hits[i].score, rank: i);
    }
    return RagResult(hits: hits, context: _assemble(hits));
  }

  Future<List<double>> _safeEmbed(String text) async {
    final embed = embedder;
    if (embed == null) return const [];
    try {
      return await embed(text);
    } catch (_) {
      return const [];
    }
  }

  static double _lexicalOverlap(String query, String text) {
    final q = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    if (q.isEmpty) return 0;
    final t = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    if (t.isEmpty) return 0;
    return q.where((w) => t.contains(w)).length / q.length;
  }

  String _assemble(List<RagHit> hits) {
    if (hits.isEmpty) return '';
    final buffer = StringBuffer();
    for (final hit in hits) {
      buffer
        ..writeln('[${hit.rank + 1}] sumber: ${hit.chunk.docId}')
        ..writeln(hit.chunk.text)
        ..writeln();
    }
    return buffer.toString().trim();
  }
}
