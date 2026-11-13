import 'dart:typed_data';

import 'embedding.dart';
import 'vault_index.dart';

class LinkSuggestion {
  const LinkSuggestion({
    required this.fromPath,
    required this.toPath,
    required this.score,
  });

  final String fromPath;
  final String toPath;
  final double score;
}

/// Suggests links between notes that are semantically close but not yet
/// linked in either direction (AI-25). Suggestions are advisory only — the
/// caller always decides whether to accept them.
abstract final class LinkSuggester {
  static const defaultMinScore = 0.35;
  static const defaultMaxNotes = 5000;

  static Future<List<LinkSuggestion>> suggest(
    List<IndexedNote> notes, {
    EmbeddingProvider embedder = const _DefaultEmbedder(),
    int limit = 20,
    double minScore = defaultMinScore,
    int maxNotes = defaultMaxNotes,
  }) async {
    if (notes.length > maxNotes) {
      throw ArgumentError(
        'vault terlalu besar untuk saran tautan P2 (maks $maxNotes catatan)',
      );
    }
    if (notes.length < 2) return const [];

    final vectors = [
      for (final note in notes)
        QuantizedVector.encode(
          embedder.embed(_representativeText(note)),
          embedder.modelVersion,
        ),
    ];

    final existing = <(String, String)>{};
    final byBasename = <String, String>{};
    final byPath = <String, String>{};
    for (final note in notes) {
      byPath[note.path.replaceAll(RegExp(r'\.md$'), '')] = note.path;
      byBasename.putIfAbsent(
        note.path.split('/').last.replaceAll(RegExp(r'\.md$'), ''),
        () => note.path,
      );
    }
    for (final note in notes) {
      for (final link in note.links) {
        if (link.embed || link.target.isEmpty) continue;
        final resolved = resolveTarget(link.target, byBasename, byPath);
        if (resolved == null) continue;
        existing
          ..add((note.path, resolved))
          ..add((resolved, note.path));
      }
    }

    final suggestions = <LinkSuggestion>[];
    for (var i = 0; i < notes.length; i++) {
      for (var j = i + 1; j < notes.length; j++) {
        if (existing.contains((notes[i].path, notes[j].path))) continue;
        final score = vectors[i].cosine(vectors[j]);
        if (score >= minScore) {
          suggestions.add(LinkSuggestion(
            fromPath: notes[i].path,
            toPath: notes[j].path,
            score: score,
          ));
        }
      }
    }
    suggestions.sort((a, b) => b.score.compareTo(a.score));
    return suggestions.take(limit).toList();
  }

  static String _representativeText(IndexedNote note) {
    final buffer = StringBuffer(note.title);
    for (final chunk in note.chunks) {
      buffer
        ..writeln()
        ..write(chunk.text);
    }
    return buffer.toString();
  }
}

class _DefaultEmbedder implements EmbeddingProvider {
  const _DefaultEmbedder();

  static final HashingEmbedder _inner = HashingEmbedder();

  @override
  int get dimension => _inner.dimension;

  @override
  String get modelVersion => _inner.modelVersion;

  @override
  Float32List embed(String text) => _inner.embed(text);
}
