import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_security/agent_security.dart';

/// Durable, file-backed [SessionStore] (PRD P0: persistent session store).
///
/// Works without native SQLite so it is usable in degraded/eco mode on
/// Termux. Writes are atomic (temp file + rename) and serialized.
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
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writeChain = Future<void>.value();
  final SecretRedactor _redactor = SecretRedactor();

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadFromDisk().whenComplete(() {
      _loaded = true;
      _loading = null;
    });
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

  Future<void> _persist() {
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
    // Let the current operation observe its own I/O failure, while allowing a
    // later queued write to proceed after that failure.
    final previous = _writeChain.catchError((Object _) {});
    final next = previous.then((_) async {
      final target = File(path);
      await target.parent.create(recursive: true);
      final nonce = '${pid}-${DateTime.now().microsecondsSinceEpoch}';
      final tmp = File('$path.$nonce.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(path);
    });
    _writeChain = next;
    return next;
  }

  @override
  Future<Session> getOrCreate(
    String sessionId, {
    required String channel,
    required String userKey,
  }) async {
    await _ensureLoaded();
    final existing = _sessions[sessionId];
    if (existing != null) return existing;
    final s = Session(id: sessionId, channel: channel, userKey: userKey);
    _sessions[sessionId] = s;
    _messages[sessionId] = [];
    _turns[sessionId] = 0;
    await _persist();
    return s;
  }

  @override
  Future<List<ChatMessage>> recent(String sessionId, {int limit = 20}) async {
    await _ensureLoaded();
    final all = _messages[sessionId] ?? const <Map<String, String>>[];
    final start = all.length > limit ? all.length - limit : 0;
    return [
      for (final m in all.sublist(start))
        ChatMessage(role: m['role']!, content: m['content']!),
    ];
  }

  @override
  Future<void> appendTurn(
    String sessionId, {
    required String user,
    required String assistant,
    List<String> tools = const [],
  }) async {
    await _ensureLoaded();
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
  }

  @override
  Future<List<SessionInfo>> list() async {
    await _ensureLoaded();
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
  }

  @override
  Future<bool> delete(String sessionId) async {
    await _ensureLoaded();
    final existed = _sessions.remove(sessionId) != null;
    _messages.remove(sessionId);
    _turns.remove(sessionId);
    if (existed) await _persist();
    return existed;
  }
}
