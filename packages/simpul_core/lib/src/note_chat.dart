/// AI chat with note context (AI-U01, AI-U02, AI-U05).
///
/// Builds a context window from the active note, a folder, or the whole
/// vault (lexical ranking), sends one prompt to the local LLM, and returns
/// the answer together with the sources used and an estimated token count.
/// Every request is checked against the vault AI policy (AI-42, fail-closed
/// on `deny`/`ask` without explicit confirmation) and written to the audit
/// log (AI-43).
library;

import 'dart:convert';
import 'dart:io';

import 'ai_permissions.dart';
import 'ollama_chat.dart';
import 'vault_scanner.dart';

/// How much of the vault the chat may see.
enum NoteChatScope { note, folder, vault }

/// One cited source behind an answer.
class ChatSource {
  const ChatSource({
    required this.path,
    required this.headingPath,
    required this.score,
  });

  final String path;
  final String headingPath;
  final double score;
}

/// The result of one chat turn.
class NoteChatAnswer {
  const NoteChatAnswer({
    required this.answer,
    required this.sources,
    required this.contextTokens,
    required this.scope,
  });

  final String answer;
  final List<ChatSource> sources;
  final int contextTokens;
  final NoteChatScope scope;
}

/// Stateless helper: builds the AI provenance block (DIF-03) so an answer
/// can be inserted into a note with an explicit "ditulis AI" marker.
abstract final class NoteChatInsertion {
  /// Renders [answer] as a quoted callout block with model + timestamp.
  static String block(
    String answer, {
    required String model,
    DateTime? now,
  }) {
    final stamp = now ?? DateTime.now();
    String pad2(int v) => v.toString().padLeft(2, '0');
    final header = '> [!ai] Ditulis AI (model: $model, '
        '${stamp.year}-${pad2(stamp.month)}-${pad2(stamp.day)} '
        '${pad2(stamp.hour)}:${pad2(stamp.minute)})';
    final body = const LineSplitter()
        .convert(answer)
        .map((l) => l.isEmpty ? '>' : '> $l')
        .join('\n');
    return '$header\n$body\n';
  }
}

/// Chat session over a vault. The LLM call is injectable via [chat] for
/// tests; lexical ranking is deterministic so no network is needed for
/// context building.
class NoteChatSession {
  NoteChatSession({
    required this.vaultDir,
    OllamaChat? chat,
    AiAccessPolicy? policy,
    AiAuditLogger? audit,
    this.maxContextChars = 8000,
    this.maxFolderNotes = 20,
    this.maxSources = 5,
  })  : chat = chat ?? OllamaChat(),
        policy = policy ?? _loadPolicy(vaultDir),
        audit = audit ?? AiAuditLogger(vaultDir);

  final String vaultDir;
  final OllamaChat chat;
  final AiAccessPolicy policy;
  final AiAuditLogger audit;
  final int maxContextChars;
  final int maxFolderNotes;
  final int maxSources;

  static AiAccessPolicy _loadPolicy(String vaultDir) {
    try {
      return AiAccessPolicy.load(vaultDir);
    } on FormatException {
      return AiAccessPolicy.denyAll();
    }
  }

  /// Rough token estimate (4 chars/token, conservative for Indonesian).
  static int estimateTokens(String text) => (text.length / 4).ceil();

  /// Asks [question] with context selected by [scope].
  ///
  /// - [notePath]: required for [NoteChatScope.note].
  /// - [folder]: optional folder prefix filter for [NoteChatScope.folder].
  /// - [confirmAsk]: set by the UI after the user approves an `ask` note.
  Future<NoteChatAnswer> ask(
    String question, {
    required NoteChatScope scope,
    String? notePath,
    String? folder,
    bool confirmAsk = false,
  }) async {
    if (question.trim().isEmpty) {
      throw ArgumentError('pertanyaan kosong');
    }
    final notes = await VaultScanner.scan(vaultDir);
    final selected = _selectNotes(notes, scope, notePath, folder);
    if (selected.isEmpty) {
      throw StateError('tidak ada catatan dalam cakupan yang dipilih');
    }
    await preload(selected.map((n) => n.path));
    for (final note in selected) {
      final decision = policy.decide(
        note.path,
        tags: note.parsed.tags.toSet(),
        noteAiAccess: note.parsed.props['ai-access'],
      );
      final allowed =
          decision == AiAccessDecision.allow || (confirmAsk && decision == AiAccessDecision.ask);
      if (!allowed) {
        audit.log(
          tool: 'note-chat',
          target: note.path,
          decision: decision,
          detail: {'scope': scope.name, 'question': question},
        );
        throw AiAccessDenied(decision, note.path);
      }
    }

    final context = _buildContext(selected, question);
    final prompt = 'Konteks catatan (jangan mengarang di luar konteks):\n\n'
        '$context\n\nPertanyaan: ${question.trim()}\n\n'
        'Jawab dalam Bahasa Indonesia, sebutkan bagian konteks yang dipakai.';
    final answer = await chat.complete(prompt);
    audit.log(
      tool: 'note-chat',
      target: selected.first.path,
      decision: AiAccessDecision.allow,
      detail: {
        'scope': scope.name,
        'notes': selected.length,
        'question': question,
      },
    );
    return NoteChatAnswer(
      answer: answer,
      sources: _topSources(selected, question),
      contextTokens: estimateTokens(context),
      scope: scope,
    );
  }

  List<ScannedNote> _selectNotes(
    List<ScannedNote> notes,
    NoteChatScope scope,
    String? notePath,
    String? folder,
  ) {
    switch (scope) {
      case NoteChatScope.note:
        if (notePath == null || notePath.isEmpty) {
          throw ArgumentError('scope note butuh notePath');
        }
        return notes.where((n) => n.path == notePath).toList();
      case NoteChatScope.folder:
        final prefix = folder == null || folder.isEmpty
            ? ''
            : '$folder/';
        final inFolder = notes
            .where((n) => prefix.isEmpty || n.path.startsWith(prefix))
            .toList()
          ..sort((a, b) => b.mtimeNs.compareTo(a.mtimeNs));
        return inFolder.take(maxFolderNotes).toList();
      case NoteChatScope.vault:
        return _rankByRelevance(notes, question: '');
    }
  }

  /// Lexical term-overlap ranking over titles, tags, and aliases. Bodies
  /// are loaded only for the selected candidates (keeps big vaults cheap).
  List<ScannedNote> _rankByRelevance(List<ScannedNote> notes,
      {String question = ''}) {
    final terms = _terms(question).toSet();
    final scored = <(double, ScannedNote)>[];
    for (final note in notes) {
      final text = '${note.parsed.title} '
          '${note.parsed.tags.join(' ')} '
          '${note.parsed.aliases.join(' ')}';
      var score = 0.0;
      for (final term in _terms(text)) {
        if (terms.contains(term)) score += 1.0;
      }
      scored.add((score, note));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(maxFolderNotes).map((s) => s.$2).toList();
  }

  static Set<String> _terms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9\u00C0-\u024F]+'))
      .where((t) => t.length >= 3)
      .toSet();

  String _buildContext(List<ScannedNote> notes, String question) {
    final buf = StringBuffer();
    var used = 0;
    for (final note in notes) {
      final body = _bodies[note.path] ?? '';
      final header = '## ${note.parsed.title} (${note.path})\n';
      final budget = maxContextChars - used;
      if (budget <= 0) break;
      final chunk = body.length > budget ? '${body.substring(0, budget)}...' : body;
      buf.write(header);
      buf.write(chunk);
      buf.write('\n\n');
      used += header.length + chunk.length + 2;
    }
    return buf.toString();
  }

  List<ChatSource> _topSources(List<ScannedNote> notes, String question) {
    final terms = _terms(question);
    final scored = <(double, ScannedNote)>[];
    for (final note in notes) {
      final text =
          '${note.parsed.title} ${note.parsed.tags.join(' ')} ${_bodies[note.path] ?? ''}';
      var score = 0.0;
      for (final term in _terms(text)) {
        if (terms.contains(term)) score += 1.0;
      }
      scored.add((score, note));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (score, note) in scored.take(maxSources))
        ChatSource(
          path: note.path,
          headingPath: note.parsed.title,
          score: score,
        ),
    ];
  }

  /// Note bodies, read lazily once per session. Public read for tests.
  final Map<String, String> _bodies = {};

  /// Loads note bodies for the given paths (called by [ask] internally via
  /// [preload]; exposed so UIs can warm the cache while the user types).
  Future<void> preload(Iterable<String> paths) async {
    for (final path in paths) {
      if (_bodies.containsKey(path)) continue;
      final file = File(
          '$vaultDir${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}');
      if (await file.exists()) {
        _bodies[path] = await file.readAsString();
      }
    }
  }
}
