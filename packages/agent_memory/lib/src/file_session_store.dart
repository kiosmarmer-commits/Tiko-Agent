import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart';

/// Durable, file-backed [SessionStore] (PRD P0: persistent session store).
///
/// Works without native SQLite so it is usable in degraded/eco mode on
/// Termux. Every public operation is serialized in-process (async chain)
/// and across processes (exclusive lock file + refresh-under-lock), so two
/// processes - or two concurrent turns in one process - can never lose
/// each other's updates. Writes are atomic (temp file + rename).
class FileSessionStore implements SessionStore {
  FileSessionStore({
    required this.path,
    this.maxMessagesPerSession = 200,
  });

  final String path;
  final int maxMessagesPerSession;

  final Map<String, Session> _sessions = {};
  final Map<String, List<Map<String, String>>> _messages = {};
  final Map<String, int> _turns = {};
  Future<void> _chain = Future<void>.value();
  final SecretRedactor _redactor = SecretRedactor();

  /// Serializes operations inside this process: the next operation only
  /// starts after the previous one (even a failed one) has finished.
  Future<T> _transaction<T>(Future<T> Function() action) {
    final previous = _chain.catchError((Object _) {});
    final next = previous.then((_) => action());
    _chain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Exclusive lock on `sessions.json.lock`, shared by every process that
  /// opens the same store, so the refresh + persist pair of one operation
  /// is atomic against other processes.
  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    final lockFile = File('$path.lock');
    await lockFile.parent.create(recursive: true);
    final raf = await lockFile.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
      try {
        return await action();
      } finally {
        await raf.unlock();
      }
    } finally {
      await raf.close();
    }
  }

  /// Reloads state from disk, discarding the in-memory copy. Called under
  /// the lock so this process always mutates the freshest on-disk state
  /// instead of a stale snapshot cached from an earlier operation.
  Future<void> _refreshFromDisk() async {
    _sessions.clear();
    _messages.clear();
    _turns.clear();
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    final f = File(path);
    if (!await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      final sessions = (raw is Map ? raw['sessions'] : null) as Map?;
      if (sessions == null) return;
      for (final e in sessions.entries) {
        final id = e.key as String;
        final v = Map<String, dynamic>.from(e.value as Map);
        _sessions[id] = Session(
          id: id,
          channel: v['channel'] as String? ?? 'unknown',
          userKey: v['user'] as String? ?? '',
          title: v['title'] is String ? _redactor.redact(v['title'] as String) : null,
          summary: v['summary'] is String ? _redactor.redact(v['summary'] as String) : null,
          createdAt: DateTime.tryParse(v['created_at'] as String? ?? ''),
          updatedAt: DateTime.tryParse(v['updated_at'] as String? ?? ''),
        );
        _turns[id] = (v['turns'] as num?)?.toInt() ?? 0;
        _messages[id] = [
          for (final m in (v['messages'] as List? ?? const []))
            {
              'role': (m as Map)['role'] as String,
              'content': _redactor.redact(m['content'] as String),
            },
        ];
      }
    } catch (_) {
      // Corrupt file: keep a copy for forensics and start clean.
      try {
        await f.rename('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
      _sessions.clear();
      _messages.clear();
      _turns.clear();
    }
  }

  Future<void> _persist() async {
    final snapshot = jsonEncode({
      'version': 1,
      'sessions': {
        for (final e in _sessions.entries)
          e.key: {
            'channel': e.value.channel,
            'user': e.value.userKey,
            'title': e.value.title == null ? null : _redactor.redact(e.value.title!),
            'summary': e.value.summary == null ? null : _redactor.redact(e.value.summary!),
            'created_at': e.value.createdAt.toIso8601String(),
            'updated_at': e.value.updatedAt.toIso8601String(),
            'turns': _turns[e.key] ?? 0,
            'messages': _messages[e.key] ?? const [],
          },
      },
    });
    // Called under the exclusive lock, so no other process can interleave
    // between the in-memory mutation and this atomic write.
    final target = File(path);
    await target.parent.create(recursive: true);
    final nonce = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final tmp = File('$path.$nonce.tmp');
    await tmp.writeAsString(snapshot, flush: true);
    await tmp.rename(path);
  }

  @override
  Future<Session> getOrCreate(
    String sessionId, {
    required String channel,
    required String userKey,
  }) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final existing = _sessions[sessionId];
      if (existing != null) return existing;
      final s = Session(id: sessionId, channel: channel, userKey: userKey);
      _sessions[sessionId] = s;
      _messages[sessionId] = [];
      _turns[sessionId] = 0;
      await _persist();
      return s;
    }));
  }

  @override
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20}) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final all = _messages[sessionId] ?? const <Map<String, String>>[];
      final start = all.length > limit ? all.length - limit : 0;
      return [
        for (final m in all.sublist(start))
          ChatMessage(role: m['role']!, content: m['content']!),
      ];
    }));
  }

  @override
  Future<void> appendTurn(
    String sessionId, {
    required String user,
    required String assistant,
    List<String> tools = const [],
  }) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final s = _sessions[sessionId];
      if (s == null) return;
      final list = _messages.putIfAbsent(sessionId, () => []);
      list
        ..add({'role': 'user', 'content': _redactor.redact(user)})
        ..add({'role': 'assistant', 'content': _redactor.redact(assistant)});
      if (list.length > maxMessagesPerSession) {
        list.removeRange(0, list.length - maxMessagesPerSession);
      }
      _turns[sessionId] = (_turns[sessionId] ?? 0) + 1;
      s.updatedAt = DateTime.now().toUtc();
      s.title ??= user.length > 60 ? '${user.substring(0, 60)}…' : user;
      await _persist();
    }));
  }

  @override
  Future<List<SessionInfo>> list() {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final out = [
        for (final s in _sessions.values)
          SessionInfo(
            id: s.id,
            channel: s.channel,
            userKey: s.userKey,
            title: s.title,
            updatedAt: s.updatedAt,
            turns: _turns[s.id] ?? 0,
          ),
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return out;
    }));
  }

  @override
  Future<bool> delete(String sessionId) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final existed = _sessions.remove(sessionId) != null;
      _messages.remove(sessionId);
      _turns.remove(sessionId);
      if (existed) await _persist();
      return existed;
    }));
  }

  @override
  Future<List<SessionSearchHit>> searchSessions(
    String query, {
    int limit = 8,
  }) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      return searchSessionsSync(query, limit: limit);
    }));
  }

  /// Synchronous cross-conversation search over the in-memory snapshot.
  /// Ranking: term frequency per message, with a recency bonus so newer
  /// conversations surface first on ties. Snippets are already redacted
  /// because [_loadFromDisk]/[appendTurn] redact every stored message.
  List<SessionSearchHit> searchSessionsSync(String query, {int limit = 8}) {
    final terms = _searchTerms(query);
    if (terms.isEmpty) return const <SessionSearchHit>[];
    final now = DateTime.now().toUtc();
    final hits = <SessionSearchHit>[];
    for (final entry in _messages.entries) {
      final sessionId = entry.key;
      final session = _sessions[sessionId];
      final ageDays = session == null
          ? 0.0
          : now.difference(session.updatedAt.toUtc()).inMinutes / 1440.0;
      final recencyBonus = (1.0 / (1.0 + ageDays)) * 0.5;
      for (final m in entry.value) {
        final content = m['content'] ?? '';
        final lower = content.toLowerCase();
        var tf = 0;
        var allTerms = true;
        for (final t in terms) {
          final count = _countOccurrences(lower, t);
          if (count == 0) {
            allTerms = false;
          } else {
            tf += count;
          }
        }
        if (!allTerms) continue;
        final score = (1.0 + tf) / (1.0 + content.length / 512.0) + recencyBonus;
        hits.add(SessionSearchHit(
          sessionId: sessionId,
          role: m['role'] ?? 'user',
          snippet: _snippet(content, terms),
          score: score,
          title: session?.title,
          timestamp: session?.updatedAt,
        ));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// Lowercased, non-empty query tokens (minimum 2 chars so single filler
  /// characters do not match everything).
  List<String> _searchTerms(String query) {
    return query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u00C0-\u024F\u4E00-\u9FFF]+'))
        .where((t) => t.length >= 2)
        .toSet()
        .toList();
  }

  int _countOccurrences(String haystack, String needle) {
    var count = 0;
    var idx = haystack.indexOf(needle);
    while (idx >= 0) {
      count++;
      idx = haystack.indexOf(needle, idx + needle.length);
    }
    return count;
  }

  /// Extracts a window around the first matching term, clamped to word-ish
  /// boundaries where possible.
  String _snippet(String content, List<String> terms) {
    var first = -1;
    for (final t in terms) {
      final idx = content.toLowerCase().indexOf(t);
      if (idx >= 0 && (first < 0 || idx < first)) first = idx;
    }
    const window = 120;
    if (first < 0) {
      return content.length <= window ? content : '${content.substring(0, window)}…';
    }
    final start = (first - 40).clamp(0, content.length);
    final end = (first + window).clamp(0, content.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < content.length ? '…' : '';
    return '$prefix${content.substring(start, end).trim()}$suffix';
  }
}
