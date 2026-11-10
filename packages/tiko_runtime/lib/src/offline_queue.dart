import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'cross_process_lock.dart';

/// Durable offline prompt queue with explicit acknowledgement.
///
/// Legacy JSONL entries (without a status field) are treated as pending.
/// A claimed entry is leased; if the process dies, it becomes claimable again
/// after [leaseDuration]. Successful work is acknowledged, never silently
/// deleted before execution completes.
///
/// Every operation runs under an in-process mutex and a cross-process file
/// lock, and re-reads the file first, so a CLI drain and a daemon sharing the
/// same queue cannot claim, acknowledge or compact over each other
/// (P0 §7 / Full Repair §6.7).
class OfflineQueue {
  OfflineQueue(this.dir, {
    this.leaseDuration = const Duration(minutes: 3),
    this.maxEntries = 10000,
  }) {
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration', 'must be positive');
    }
    if (maxEntries < 1 || maxEntries > 100000) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be 1..100000');
    }
  }

  final String dir;
  final Duration leaseDuration;
  final int maxEntries;
  final Uuid _uuid = const Uuid();
  Future<void> _mutex = Future<void>.value();

  /// Cross-process lock guarding the queue file between independent
  /// processes (CLI vs daemon). Acquired only after the in-process mutex, in
  /// the same order everywhere, so the two lock layers cannot deadlock.
  late final CrossProcessLock _fileLock = CrossProcessLock(
    _file,
    timeout: const Duration(seconds: 10),
  );

  String get _file => p.join(dir, 'offline_queue.jsonl');

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _mutex;
    final release = Completer<void>();
    _mutex = release.future;
    await previous;
    final ticket = await _fileLock.acquire();
    try {
      return await action();
    } finally {
      await ticket.release();
      release.complete();
    }
  }

  Future<void> enqueue({
    required String text,
    String sessionId = 'offline',
    String channel = 'cli',
  }) => _locked(() async {
    final clean = text.trim();
    if (clean.isEmpty) throw ArgumentError.value(text, 'text', 'must not be empty');
    await Directory(dir).create(recursive: true);
    final entries = await _readAll();
    final activeCount = entries.where((e) => e['status'] != 'acked').length;
    if (activeCount >= maxEntries) {
      throw StateError('offline queue is full ($maxEntries entries)');
    }
    entries.add({
      'id': 'oq_${_uuid.v4()}',
      'text': clean,
      'session_id': sessionId,
      'channel': channel,
      'at': DateTime.now().toUtc().toIso8601String(),
      'status': 'pending',
      'attempts': 0,
    });
    await _writeAll(_compact(entries));
  });

  /// Returns oldest pending items first. Active leases are excluded until
  /// their lease expires, preventing two workers from processing one item.
  Future<List<Map<String, dynamic>>> peek({int limit = 50}) => _locked(() async {
    final now = DateTime.now().toUtc();
    final items = await _readAll();
    return items.where((e) => _isClaimable(e, now)).take(_safeLimit(limit)).toList();
  });

  /// Atomically lease entries before handing them to the caller.
  Future<List<Map<String, dynamic>>> claim({int limit = 50}) => _locked(() async {
    final now = DateTime.now().toUtc();
    final entries = await _readAll();
    final claimed = <Map<String, dynamic>>[];
    for (final item in entries) {
      if (!_isClaimable(item, now) || claimed.length >= _safeLimit(limit)) continue;
      item['status'] = 'in_flight';
      item['claimed_at'] = now.toIso8601String();
      // A fresh lease token prevents an expired worker from acknowledging or
      // releasing work after another worker has reclaimed the same item.
      item['claim_token'] = 'qct_${_uuid.v4()}';
      item['attempts'] = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
      claimed.add(Map<String, dynamic>.from(item));
    }
    if (claimed.isNotEmpty) await _writeAll(_compact(entries));
    return claimed;
  });

  /// Backward-compatible alias. Unlike the old implementation, this does not
  /// delete entries; callers must call [ack] or [retry] for every item.
  @Deprecated('Use claim(), then ack() or retry() for each item.')
  Future<List<Map<String, dynamic>>> drain() => claim(limit: maxEntries);

  Future<bool> ack(String id, {required String claimToken}) => _locked(() async {
    final entries = await _readAll();
    final index = entries.indexWhere((e) => e['id'] == id);
    if (index < 0 || entries[index]['status'] != 'in_flight' ||
        entries[index]['claim_token'] != claimToken ||
        !_leaseIsCurrent(entries[index], DateTime.now().toUtc())) {
      return false;
    }
    entries[index]
      ..['status'] = 'acked'
      ..['acknowledged_at'] = DateTime.now().toUtc().toIso8601String()
      ..remove('claimed_at')
      ..remove('claim_token')
      ..remove('last_error');
    await _writeAll(_compact(entries));
    return true;
  });

  Future<bool> retry(String id, {required String claimToken, String? error}) => _locked(() async {
    final entries = await _readAll();
    final index = entries.indexWhere((e) => e['id'] == id);
    if (index < 0 || entries[index]['status'] != 'in_flight' ||
        entries[index]['claim_token'] != claimToken ||
        !_leaseIsCurrent(entries[index], DateTime.now().toUtc())) {
      return false;
    }
    entries[index]
      ..['status'] = 'pending'
      ..remove('claimed_at')
      ..remove('claim_token');
    if (error != null && error.isNotEmpty) {
      entries[index]['last_error'] = error.length > 500 ? error.substring(0, 500) : error;
    }
    await _writeAll(_compact(entries));
    return true;
  });

  Future<int> length() => _locked(() async {
    final entries = await _readAll();
    return entries.where((e) => e['status'] != 'acked').length;
  });

  Future<List<Map<String, dynamic>>> _readAll() async {
    final file = File(_file);
    if (!await file.exists()) return [];
    final fileSize = await file.length();
    if (fileSize > 64 * 1024 * 1024) {
      throw StateError('offline queue exceeds 64 MiB; refusing unsafe partial load');
    }
    final out = <Map<String, dynamic>>[];
    final corrupt = <String>[];
    final seenIds = <String>{};
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) throw const FormatException('entry is not a mapping');
        final item = Map<String, dynamic>.from(decoded);
        final id = item['id'];
        final text = item['text'];
        if (id is! String || id.isEmpty || !seenIds.add(id) ||
            text is! String || text.trim().isEmpty || text.length > 100000) {
          throw const FormatException('entry has no valid/unique id or text');
        }
        item['status'] = item['status'] is String ? item['status'] : 'pending';
        if (!const {'pending', 'in_flight', 'acked'}.contains(item['status'])) {
          item['status'] = 'pending';
        }
        final attempts = (item['attempts'] as num?)?.toInt() ?? 0;
        if (attempts < 0 || attempts > 1000000) {
          throw const FormatException('entry attempts are out of range');
        }
        item['attempts'] = attempts;
        if (item['status'] == 'in_flight' &&
            (item['claim_token'] is! String || (item['claim_token'] as String).isEmpty)) {
          // Legacy or truncated lease has no owner token; make it claimable.
          item['status'] = 'pending';
          item.remove('claimed_at');
          item.remove('claim_token');
        }
        out.add(item);
      } catch (_) {
        corrupt.add(line);
      }
    }
    if (corrupt.isNotEmpty) {
      final quarantine = File('$_file.corrupt');
      await quarantine.writeAsString('${corrupt.join('\n')}\n', mode: FileMode.append, flush: true);
    }
    return out;
  }

  bool _leaseIsCurrent(Map<String, dynamic> entry, DateTime now) {
    final raw = entry['claimed_at'];
    final claimed = raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    return claimed != null && now.difference(claimed) < leaseDuration;
  }

  bool _isClaimable(Map<String, dynamic> entry, DateTime now) {
    final status = entry['status'] ?? 'pending';
    if (status == 'acked') return false;
    if (status != 'in_flight') return true;
    return !_leaseIsCurrent(entry, now);
  }

  int _safeLimit(int limit) => limit.clamp(1, maxEntries).toInt();

  List<Map<String, dynamic>> _compact(List<Map<String, dynamic>> entries) {
    // Keep a bounded acknowledgement tail for diagnostics/idempotent retries.
    final active = entries.where((e) => e['status'] != 'acked').toList();
    final done = entries.where((e) => e['status'] == 'acked').toList();
    final keepDone = done.length > 500 ? done.sublist(done.length - 500) : done;
    return [...active, ...keepDone];
  }

  Future<void> _writeAll(List<Map<String, dynamic>> entries) async {
    await Directory(dir).create(recursive: true);
    final target = File(_file);
    final temp = File('$_file.${_uuid.v4()}.tmp');
    final content = entries.map(jsonEncode).join('\n');
    await temp.writeAsString(content.isEmpty ? '' : '$content\n', flush: true);
    try {
      await temp.rename(target.path);
    } on FileSystemException {
      // Portable replacement with rollback: never delete the last complete
      // copy until the newly written file has been installed successfully.
      final backup = File('$_file.bak');
      var movedOld = false;
      try {
        if (await target.exists()) {
          if (await backup.exists()) await backup.delete();
          await target.rename(backup.path);
          movedOld = true;
        }
        await temp.rename(target.path);
        if (movedOld && await backup.exists()) await backup.delete();
      } catch (_) {
        if (movedOld && !await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
    }
  }
}
