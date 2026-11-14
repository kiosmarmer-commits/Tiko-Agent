import 'embedding.dart';
import 'ollama_chat.dart';
import 'semantic_index.dart';
import 'vault_index.dart';

/// Rough token estimate for context budgeting (AI-23); ~4 characters per
/// token is accurate enough for budgeting, not for billing.
int estimateTokens(String text) => (text.length / 4).ceil();

/// One cited evidence block ("tanya vault", AI-21): every claim in an answer
/// links back to a note + heading via [id].
class RagChunk {
  const RagChunk({
    required this.id,
    required this.path,
    required this.headingPath,
    required this.text,
    required this.score,
  });

  final int id;
  final String path;
  final String headingPath;
  final String text;
  final double score;

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'heading_path': headingPath,
        'score': score,
      };
}

class RagAnswer {
  const RagAnswer({
    required this.mode,
    required this.answer,
    required this.citations,
    this.usedTokens = 0,
  });

  /// `llm` (generated from context), `extractive` (evidence returned as-is
  /// when no LLM is configured), or `not_found` (AI-22).
  final String mode;
  final String answer;
  final List<RagChunk> citations;
  final int usedTokens;

  Map<String, Object?> toJson() => {
        'mode': mode,
        'answer': answer,
        'used_tokens': usedTokens,
        'citations': [for (final c in citations) c.toJson()],
      };
}

/// AI-30: lexical pre-candidates so vector search can be restricted to a
/// candidate set instead of scanning every vector at T3/T4 scale.
Future<Set<String>> lexicalPrefilter(
  VaultIndex index,
  String query, {
  int limit = 50,
}) async {
  final hits = await index.search(query, limit: limit);
  return {for (final hit in hits) hit.path};
}

/// "Tanya vault" (AI-21/22/23): retrieve evidence (lexical + semantic fused
/// with RRF), assemble a citation-labelled context within a token budget,
/// then either generate an answer through a local LLM or return the evidence
/// extractively. Without enough evidence the answer states that explicitly
/// (AI-22) — never a guess.
class VaultAnswerer {
  VaultAnswerer({
    required this.index,
    required this.embedder,
    this.semantic,
    this.chat,
    this.tokenBudget = 2048,
    this.minScore = 0.15,
    this.maxChunks = 8,
    this.rrfK = 60,
  });

  final VaultIndex index;
  final EmbeddingProvider embedder;
  final SemanticIndex? semantic;
  final OllamaChat? chat;
  final int tokenBudget;
  final double minScore;
  final int maxChunks;
  final int rrfK;

  static const _systemPrompt =
      'Anda asisten vault lokal. Jawab HANYA dari konteks yang diberikan. '
      'Setiap klaim wajib menyertakan sitasi [n] sesuai nomor konteks. '
      'Jika bukti tidak cukup, nyatakan dengan jelas bahwa jawaban tidak '
      'ditemukan di vault. Jangan menambah informasi di luar konteks.';

  Future<RagAnswer> ask(
    String question, {
    int limit = 8,
    Set<String>? allowedPaths,
  }) async {
    final lexical = [
      for (final hit in await index.search(question, limit: limit * 3))
        if (allowedPaths == null || allowedPaths.contains(hit.path)) hit,
    ];
    final semanticHits = semantic == null
        ? const <SemanticHit>[]
        : await semantic!.search(
            embedder.embed(question),
            limit: limit * 3,
            allowedPaths: allowedPaths,
          );

    if (lexical.isEmpty &&
        (semanticHits.isEmpty || semanticHits.first.score < minScore)) {
      return const RagAnswer(
        mode: 'not_found',
        answer: 'Tidak ditemukan bukti yang cukup di vault untuk pertanyaan '
            'ini (AI-22: jawaban tidak dikarang).',
        citations: [],
      );
    }

    final rrf = <String, double>{};
    for (var rank = 0; rank < lexical.length; rank++) {
      final path = lexical[rank].path;
      rrf[path] = (rrf[path] ?? 0) + 1 / (rrfK + rank + 1);
    }
    for (var rank = 0; rank < semanticHits.length; rank++) {
      final path = semanticHits[rank].notePath;
      rrf[path] = (rrf[path] ?? 0) + 1 / (rrfK + rank + 1);
    }
    final orderedPaths = [
      for (final entry in rrf.entries) (entry.key, entry.value),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    final bestChunkByPath = <String, ({int ord, double score})>{};
    for (final hit in semanticHits) {
      final existing = bestChunkByPath[hit.notePath];
      if (existing == null || hit.score > existing.score) {
        bestChunkByPath[hit.notePath] = (ord: hit.ord, score: hit.score);
      }
    }
    final lexicalByPath = {for (final hit in lexical) hit.path: hit};

    final evidence = <RagChunk>[];
    var usedTokens = 0;
    for (final (path, rrfScore) in orderedPaths) {
      if (evidence.length >= maxChunks) break;
      final note = await index.noteByPath(path);
      if (note == null) continue;
      final (text, heading) = _bestChunkText(note, path, lexicalByPath,
          bestChunkByPath[path]);
      if (text.isEmpty) continue;
      final tokens = estimateTokens(text);
      if (usedTokens > 0 && usedTokens + tokens > tokenBudget) continue;
      usedTokens += tokens;
      evidence.add(RagChunk(
        id: evidence.length + 1,
        path: path,
        headingPath: heading,
        text: text,
        score: rrfScore,
      ));
    }
    if (evidence.isEmpty) {
      return const RagAnswer(
        mode: 'not_found',
        answer: 'Tidak ditemukan bukti yang cukup di vault untuk pertanyaan '
            'ini (AI-22: jawaban tidak dikarang).',
        citations: [],
      );
    }

    final context = [
      for (final chunk in evidence)
        '[${chunk.id}] ${chunk.path}'
            '${chunk.headingPath.isEmpty ? '' : ' › ${chunk.headingPath}'}\n'
            '${chunk.text}',
    ].join('\n\n');

    final llm = chat;
    if (llm != null) {
      final answer = await llm.complete(
        'Pertanyaan: $question\n\nKonteks:\n$context',
        system: _systemPrompt,
      );
      return RagAnswer(
        mode: 'llm',
        answer: answer,
        citations: evidence,
        usedTokens: usedTokens,
      );
    }
    return RagAnswer(
      mode: 'extractive',
      answer: context,
      citations: evidence,
      usedTokens: usedTokens,
    );
  }

  (String, String) _bestChunkText(
    IndexedNote note,
    String path,
    Map<String, SearchHit> lexicalByPath,
    ({int ord, double score})? best,
  ) {
    if (best != null && best.ord < note.chunks.length) {
      final chunk = note.chunks[best.ord];
      return (chunk.text, chunk.headingPath);
    }
    final lexHit = lexicalByPath[path];
    if (lexHit != null) {
      for (final chunk in note.chunks) {
        if (chunk.headingPath == lexHit.headingPath && chunk.text.isNotEmpty) {
          return (chunk.text, chunk.headingPath);
        }
      }
      if (lexHit.snippet.isNotEmpty) return (lexHit.snippet, lexHit.headingPath);
    }
    if (note.chunks.isEmpty) return ('', '');
    final longest = note.chunks.reduce(
      (a, b) => a.text.length >= b.text.length ? a : b,
    );
    return (longest.text, longest.headingPath);
  }
}
