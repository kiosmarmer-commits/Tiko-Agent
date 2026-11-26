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

  /// True setelah state dimuat dari store utama yang valid; rescue hanya
  /// menimpa state in-memory bila store utama tidak menyediakan sesi itu.
  bool _loadedFromMain = false;

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
    _loadedFromMain = false;
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    final f = File(path);
    if (!await f.exists()) {
      // Store utama hilang (mis. diganti proses lain/migrasi): pulihkan
      // sesi dari file rescue bila ada (Hermes `session_rescue.py`).
      await _absorbRescueFile();
      return;
    }
    try {
      final raw = jsonDecode(await f.readAsString());
      final sessions = (raw is Map ? raw['sessions'] : null) as Map?;
      if (sessions == null) return;
      for (final e in sessions.entries) {
        _applySessionEntry(e.key as String, e.value as Map);
      }
      _loadedFromMain = true;
    } catch (_) {
      // Corrupt file: keep a copy for forensics and start clean.
      try {
        await f.rename('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {} // best-effort
      _sessions.clear();
      _messages.clear();
      _turns.clear();
    }
    // Sesi yang tertinggal di file rescue (persist gagal sebelumnya) tetap
    // di-merge bila belum ada di store utama yang lebih segar.
    await _absorbRescueFile();
  }

  /// Konstruksi satu entri sesi dari snapshot JSON (dipakai load utama dan
  /// absorb rescue; konten tetap diredaksi karena berasal dari disk).
  void _applySessionEntry(String id, Map<dynamic, dynamic> rawMap) {
    final v = Map<String, dynamic>.from(rawMap);
    _sessions[id] = Session(
      id: id,
      channel: v['channel'] as String? ?? 'unknown',
      userKey: v['user'] as String? ?? '',
      title: v['title'] is String ? _redactor.redact(v['title'] as String) : null,
      summary: v['summary'] is String ? _redactor.redact(v['summary'] as String) : null,
      provider: v['provider'] as String?,
      model: v['model'] as String?,
      pinned: v['pinned'] == true,
      archived: v['archived'] == true,
      lastFailed: v['last_failed'] == true,
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
            if (e.value.provider != null) 'provider': e.value.provider,
            if (e.value.model != null) 'model': e.value.model,
            'pinned': e.value.pinned,
            'archived': e.value.archived,
            'last_failed': e.value.lastFailed,
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
    try {
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(path);
    } catch (_) {
      // Atomic write gagal (store diganti/di-migrate di bawah proses hidup,
      // izin berubah): tuangkan snapshot ke file rescue JSONL alih-alih
      // kehilangan data (Hermes `session_rescue.py`). Rescue bersifat
      // best-effort: bila ini juga gagal, error asli tetap dilempar.
      try {
        await _spillRescue(snapshot);
      } catch (_) {
        rethrow;
      }
      return;
    }
    // Persist sukses: state sudah aman di store utama, file rescue lama
    // tidak diperlukan lagi.
    try {
      final rescue = File('$path.rescue.jsonl');
      if (await rescue.exists()) await rescue.delete();
    } catch (_) {} // best-effort
  }

  /// Batas ukuran file rescue sebelum dirotasi (mulai file baru).
  static const _maxRescueBytes = 5 * 1024 * 1024;

  /// Append satu snapshot penuh sebagai satu baris JSONL ke rescue file.
  Future<void> _spillRescue(String snapshot) async {
    final rescue = File('$path.rescue.jsonl');
    await rescue.parent.create(recursive: true);
    if (await rescue.exists() && await rescue.length() > _maxRescueBytes) {
      await rescue.delete();
    }
    final line = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'pid': pid,
      'snapshot': snapshot,
    });
    await rescue.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  /// Menggabungkan sesi-sesi dari file rescue ke state in-memory. Baris
  /// diproses kronologis: snapshot rescue yang lebih baru menimpa snapshot
  /// rescue sebelumnya untuk id yang sama. Sesi yang sudah disediakan store
  /// utama tidak ditimpa (state utama lebih segar).
  Future<void> _absorbRescueFile() async {
    final rescue = File('$path.rescue.jsonl');
    if (!await rescue.exists()) return;
    try {
      final lines = await rescue.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final entry = jsonDecode(line);
          final raw = entry is Map ? entry['snapshot'] : null;
          if (raw is! String) continue;
          final snap = jsonDecode(raw);
          final sessions = (snap is Map ? snap['sessions'] : null) as Map?;
          if (sessions == null) continue;
          for (final e in sessions.entries) {
            final id = e.key as String;
            if (_loadedFromMain && _sessions.containsKey(id)) continue;
            _applySessionEntry(id, e.value as Map);
          }
        } catch (_) {
          // Baris rescue korup: lewati, jangan gagalkan pemulihan lain.
          continue;
        }
      }
    } catch (_) {} // best-effort
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
    String? provider,
    String? model,
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
      if (provider != null) s.provider = provider;
      if (model != null) s.model = model;
      s.lastFailed = false;
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
            provider: s.provider,
            model: s.model,
            pinned: s.pinned,
            archived: s.archived,
            lastFailed: s.lastFailed,
          ),
      ]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
      return out;
    }));
  }

  @override
  Future<SessionInfo?> get(String sessionId) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      return _infoOf(_sessions[sessionId]);
    }));
  }

  SessionInfo? _infoOf(Session? s) {
    if (s == null) return null;
    return SessionInfo(
      id: s.id,
      channel: s.channel,
      userKey: s.userKey,
      title: s.title,
      updatedAt: s.updatedAt,
      turns: _turns[s.id] ?? 0,
      provider: s.provider,
      model: s.model,
      pinned: s.pinned,
      archived: s.archived,
      lastFailed: s.lastFailed,
      createdAt: s.createdAt,
    );
  }

  @override
  Future<bool> setPinned(String sessionId, bool pinned) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final s = _sessions[sessionId];
      if (s == null || s.pinned == pinned) return false;
      s.pinned = pinned;
      await _persist();
      return true;
    }));
  }

  @override
  Future<bool> setArchived(String sessionId, bool archived) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final s = _sessions[sessionId];
      if (s == null || s.archived == archived) return false;
      s.archived = archived;
      await _persist();
      return true;
    }));
  }

  @override
  Future<int> deleteMany(List<String> sessionIds) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      var removed = 0;
      for (final id in sessionIds) {
        if (_sessions.remove(id) != null) removed++;
        _messages.remove(id);
        _turns.remove(id);
      }
      if (removed > 0) await _persist();
      return removed;
    }));
  }

  @override
  Future<SessionInfo?> duplicate(String sessionId, {String? newId}) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final src = _sessions[sessionId];
      if (src == null) return null;
      final id = newId == null || newId.trim().isEmpty
          ? '${src.id}-fork-${DateTime.now().millisecondsSinceEpoch}'
          : newId.trim();
      if (_sessions.containsKey(id)) return null;
      final copy = Session(
        id: id,
        channel: src.channel,
        userKey: src.userKey,
        title:
            src.title == null ? null : '${src.title} (salinan)',
        summary: src.summary,
        provider: src.provider,
        model: src.model,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      _sessions[id] = copy;
      _messages[id] = [
        for (final m in _messages[sessionId] ?? const <Map<String, String>>[])
          Map<String, String>.of(m),
      ];
      _turns[id] = _turns[sessionId] ?? 0;
      await _persist();
      return _infoOf(copy);
    }));
  }

  @override
  Future<bool> markTurnOutcome(
    String sessionId, {
    required bool ok,
    String? provider,
    String? model,
  }) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final s = _sessions[sessionId];
      if (s == null) return false;
      if (provider != null) s.provider = provider;
      if (model != null) s.model = model;
      s.lastFailed = !ok;
      s.updatedAt = DateTime.now().toUtc();
      await _persist();
      return true;
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
  Future<bool> rename(String sessionId, String title) {
    return _transaction(() => _withFileLock(() async {
      await _refreshFromDisk();
      final s = _sessions[sessionId];
      final t = title.trim();
      if (s == null || t.isEmpty) return false;
      s.title = _redactor.redact(t);
      await _persist();
      return true;
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
