import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Migration of conversation history from other agents (Hermes-style
/// "import your history" tooling). Parsers are pure functions over file
/// contents; [AgentMigration] imports the parsed exchanges into a
/// [MemoryStore] as searchable facts.
///
/// Formats:
/// - `claude_code` — Claude Code session JSONL
///   (`~/.claude/projects/<project>/*.jsonl`): one JSON object per line
///   with `type` user/assistant and `message.content`.
/// - `chatgpt` — ChatGPT data export `conversations.json`: a list of
///   conversations whose `mapping` nodes carry
///   `message.author.role` + `message.content.parts`.
/// - `generic` — a JSON list of `{role, content}` messages or
///   `{user, assistant}` pairs.

/// One user/assistant exchange extracted from a foreign history file.
class MigrationExchange {
  const MigrationExchange({
    required this.userText,
    this.assistantText,
    this.timestamp,
  });

  final String userText;
  final String? assistantText;
  final DateTime? timestamp;
}

/// Outcome of one import run.
class MigrationReport {
  const MigrationReport({
    required this.source,
    required this.exchanges,
    required this.imported,
    required this.skipped,
    this.errors = const [],
  });

  final String source;
  final int exchanges;
  final int imported;
  final int skipped;
  final List<String> errors;

  Map<String, dynamic> toJson() => {
        'source': source,
        'exchanges': exchanges,
        'imported': imported,
        'skipped': skipped,
        'errors': errors,
      };
}

class AgentMigration {
  AgentMigration({
    required this.store,
    this.maxFactChars = 300,
    this.importance = 0.4,
  });

  final MemoryStore store;

  /// Fact text cap (matches the built-in stores' own 300-char limit).
  final int maxFactChars;

  /// Score for migrated facts: below default so imported history never
  /// outranks live observations, but high enough to surface in searches.
  final double importance;

  /// Imports a history file, auto-detecting the format when [format] is
  /// null (`claude_code`, `chatgpt`, or `generic`).
  Future<MigrationReport> importFile(
    String path, {
    String? format,
    String? ownerKey,
  }) async {
    final f = File(path);
    if (!f.existsSync()) {
      throw FileSystemException('file migrasi tidak ditemukan', path);
    }
    final content = f.readAsStringSync();
    final resolved = format ?? detectFormat(path, content);
    final List<MigrationExchange> exchanges;
    switch (resolved) {
      case 'claude_code':
        exchanges = parseClaudeCodeJsonl(content);
        break;
      case 'chatgpt':
        exchanges = parseChatGptExport(content);
        break;
      case 'generic':
        exchanges = parseGenericJson(content);
        break;
      default:
        throw ArgumentError('format migrasi tidak dikenal: $resolved');
    }
    return importExchanges(exchanges, source: resolved, ownerKey: ownerKey);
  }

  /// Imports parsed exchanges as facts (`kind: 'migrated'`).
  Future<MigrationReport> importExchanges(
    List<MigrationExchange> exchanges, {
    required String source,
    String? ownerKey,
  }) async {
    var imported = 0;
    var skipped = 0;
    final errors = <String>[];
    for (var i = 0; i < exchanges.length; i++) {
      final e = exchanges[i];
      var text = 'Q: ${e.userText.trim()}';
      final a = e.assistantText?.trim() ?? '';
      if (a.isNotEmpty) text = '$text\nA: $a';
      text = text.trim();
      if (text.length < 4) {
        skipped++;
        continue;
      }
      if (text.length > maxFactChars) {
        text = text.substring(0, maxFactChars);
      }
      try {
        await store.upsertFact(Fact(
          id: '',
          text: text,
          kind: 'migrated',
          importance: importance,
          sourceSession: 'migrate:$source',
          ownerKey: ownerKey,
          createdAt: e.timestamp,
          provenance: Provenance.localFile,
          confidence: 0.6,
        ));
        imported++;
      } catch (err) {
        errors.add('exchange[$i]: $err');
      }
    }
    return MigrationReport(
      source: source,
      exchanges: exchanges.length,
      imported: imported,
      skipped: skipped,
      errors: errors,
    );
  }

  /// Detects the format from the file name and content shape.
  static String detectFormat(String path, String content) {
    if (path.endsWith('.jsonl')) return 'claude_code';
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('[')) {
      final probe = jsonDecode(content.length > 4096
          ? '${content.substring(0, 4096)}]}'
          : content);
      if (probe is List && probe.isNotEmpty && probe.first is Map) {
        final first = probe.first as Map;
        if (first.containsKey('mapping')) return 'chatgpt';
      }
      return 'generic';
    }
    return 'claude_code';
  }

  /// Parses Claude Code session JSONL into user/assistant exchanges.
  static List<MigrationExchange> parseClaudeCodeJsonl(String content) {
    final exchanges = <MigrationExchange>[];
    String? pendingUser;
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Map<String, dynamic> entry;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, dynamic>) continue;
        entry = decoded;
      } catch (_) {
        continue;
      }
      final type = entry['type'] as String?;
      if (type != 'user' && type != 'assistant') continue;
      final message = entry['message'];
      if (message is! Map) continue;
      final text = _contentText(message['content']);
      if (text.isEmpty) continue;
      final ts = DateTime.tryParse(entry['timestamp'] as String? ?? '');
      if (type == 'user') {
        if (pendingUser != null) {
          exchanges.add(MigrationExchange(userText: pendingUser));
        }
        pendingUser = text;
      } else {
        exchanges.add(MigrationExchange(
          userText: pendingUser ?? '',
          assistantText: text,
          timestamp: ts,
        ));
        pendingUser = null;
      }
    }
    if (pendingUser != null) {
      exchanges.add(MigrationExchange(userText: pendingUser));
    }
    return exchanges;
  }

  /// Parses a ChatGPT export `conversations.json` into exchanges ordered
  /// by message creation time.
  static List<MigrationExchange> parseChatGptExport(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! List) return const [];
    final events = <(DateTime?, String?, String)>[];
    for (final conv in decoded) {
      if (conv is! Map) continue;
      final mapping = conv['mapping'];
      if (mapping is! Map) continue;
      for (final node in mapping.values) {
        if (node is! Map) continue;
        final message = node['message'];
        if (message is! Map) continue;
        final author = message['author'];
        final role = author is Map ? author['role'] as String? : null;
        if (role != 'user' && role != 'assistant') continue;
        final contentPart = message['content'];
        final parts = contentPart is Map ? contentPart['parts'] : null;
        final text = [
          if (parts is List)
            for (final part in parts)
              if (part is String) part,
        ].where((s) => s.isNotEmpty).join('\n');
        if (text.isEmpty) continue;
        final ct = message['create_time'];
        final ts = ct is num
            ? DateTime.fromMillisecondsSinceEpoch((ct * 1000).round(),
                isUtc: true)
            : null;
        events.add((ts, role, text));
      }
    }
    events.sort((a, b) => (a.$1 ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(b.$1 ?? DateTime.fromMillisecondsSinceEpoch(0)));
    final exchanges = <MigrationExchange>[];
    String? pendingUser;
    for (final (_, role, text) in events) {
      if (role == 'user') {
        if (pendingUser != null) {
          exchanges.add(MigrationExchange(userText: pendingUser));
        }
        pendingUser = text;
      } else {
        exchanges.add(MigrationExchange(
          userText: pendingUser ?? '',
          assistantText: text,
        ));
        pendingUser = null;
      }
    }
    if (pendingUser != null) {
      exchanges.add(MigrationExchange(userText: pendingUser));
    }
    return exchanges;
  }

  /// Parses a generic JSON history: a list of `{role, content}` messages
  /// or `{user, assistant}` pairs.
  static List<MigrationExchange> parseGenericJson(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! List) return const [];
    final exchanges = <MigrationExchange>[];
    String? pendingUser;
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final user = raw['user'];
      final assistant = raw['assistant'];
      if (user is String) {
        if (pendingUser != null) {
          exchanges.add(MigrationExchange(userText: pendingUser));
          pendingUser = null;
        }
        pendingUser = user;
        if (assistant is String && assistant.isNotEmpty) {
          exchanges.add(MigrationExchange(
            userText: pendingUser,
            assistantText: assistant,
          ));
          pendingUser = null;
        }
        continue;
      }
      final role = raw['role'] as String?;
      final text = _contentText(raw['content']);
      if (text.isEmpty) continue;
      if (role == 'user') {
        if (pendingUser != null) {
          exchanges.add(MigrationExchange(userText: pendingUser));
        }
        pendingUser = text;
      } else if (role == 'assistant') {
        exchanges.add(MigrationExchange(
          userText: pendingUser ?? '',
          assistantText: text,
        ));
        pendingUser = null;
      }
    }
    if (pendingUser != null) {
      exchanges.add(MigrationExchange(userText: pendingUser));
    }
    return exchanges;
  }

  static String _contentText(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      return [
        for (final block in content)
          if (block is Map && (block['type'] == 'text' || block['type'] == null))
            block['text'] as String? ?? '',
      ].where((s) => s.isNotEmpty).join('\n');
    }
    return '';
  }
}
