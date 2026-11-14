import 'dart:math' as math;
import 'dart:typed_data';

import 'embedding.dart';
import 'vault_index.dart';

/// One tag suggestion for a note (AI-26). Suggestions only — applying one
/// always requires human approval, so nothing here ever writes to the vault.
class TagSuggestion {
  const TagSuggestion({
    required this.path,
    required this.tag,
    required this.score,
  });

  final String path;
  final String tag;
  final double score;
}

/// Deterministic tag suggestions (AI-26): a candidate tag scores by the
/// cosine similarity between the note's embedding and the tag's centroid
/// (mean embedding of the notes that already carry the tag). Lexical hashing
/// keeps this fully local and reproducible; a semantic embedder can replace
/// it through [EmbeddingProvider] without touching call sites.
abstract final class TagSuggester {
  static const defaultMinScore = 0.35;
  static const _maxNotes = 5000;

  static List<TagSuggestion> suggest(
    List<IndexedNote> notes, {
    EmbeddingProvider embedder = const _DefaultTagEmbedder(),
    int limit = 5,
    double minScore = defaultMinScore,
  }) {
    if (notes.length > _maxNotes) {
      throw StateError(
        'vault terlalu besar untuk saran tag ($_maxNotes catatan maksimum)',
      );
    }
    final vectors = [
      for (final note in notes) embedder.embed(_representative(note)),
    ];
    final tagSums = <String, Float32List>{};
    final tagCounts = <String, int>{};
    for (var i = 0; i < notes.length; i++) {
      for (final tag in notes[i].tags) {
        final key = tag.toLowerCase();
        final sum = tagSums.putIfAbsent(key, () => Float32List(embedder.dimension));
        final vector = vectors[i];
        for (var d = 0; d < sum.length; d++) {
          sum[d] += vector[d];
        }
        tagCounts[key] = (tagCounts[key] ?? 0) + 1;
      }
    }
    final tagCentroids = <String, Float32List>{
      for (final entry in tagSums.entries)
        entry.key: _normalized(entry.value, tagCounts[entry.key]!),
    };

    final out = <TagSuggestion>[];
    for (var i = 0; i < notes.length; i++) {
      final ownTags = {
        for (final tag in notes[i].tags) tag.toLowerCase(),
      };
      final best = <(String, double)>[];
      tagCentroids.forEach((tag, centroid) {
        if (ownTags.contains(tag) || ownTags.any((t) => t.startsWith('$tag/'))) {
          return;
        }
        final score = _cosine(vectors[i], centroid);
        if (score >= minScore) {
          best.add((tag, score));
        }
      });
      best.sort((a, b) {
        final cmp = b.$2.compareTo(a.$2);
        return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
      });
      for (final (tag, score) in best.take(limit)) {
        out.add(TagSuggestion(path: notes[i].path, tag: tag, score: score));
      }
    }
    return out;
  }

  static Float32List _normalized(Float32List sum, int count) {
    final out = Float32List(sum.length);
    var norm = 0.0;
    for (var d = 0; d < sum.length; d++) {
      out[d] = sum[d] / count;
      norm += out[d] * out[d];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var d = 0; d < sum.length; d++) {
        out[d] /= norm;
      }
    }
    return out;
  }

  static double _cosine(Float32List a, Float32List b) {
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var d = 0; d < math.min(a.length, b.length); d++) {
      dot += a[d] * b[d];
      na += a[d] * a[d];
      nb += b[d] * b[d];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  static String _representative(IndexedNote note) {
    final buffer = StringBuffer(note.title);
    for (final chunk in note.chunks) {
      buffer
        ..writeln()
        ..write(chunk.text);
    }
    return buffer.toString();
  }
}

class _DefaultTagEmbedder implements EmbeddingProvider {
  const _DefaultTagEmbedder();

  static final HashingEmbedder _inner = HashingEmbedder();

  @override
  int get dimension => _inner.dimension;

  @override
  String get modelVersion => _inner.modelVersion;

  @override
  Float32List embed(String text) => _inner.embed(text);
}
