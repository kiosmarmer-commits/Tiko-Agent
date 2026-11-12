import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:uuid/uuid.dart';

import 'cross_process_lock.dart';

enum ApprovalState { pending, approved, denied, expired }

/// Immutable-in-practice request persisted by the single approval broker.
///
/// Every surface (CLI, Telegram callback, HTTP API and Flutter) addresses this
/// same request ID. Pending requests from a previous daemon run are expired
/// only after a newly started daemon successfully acquires the instance lock.
class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.sessionId,
    required this.tool,
    required this.args,
    required this.risk,
    required this.createdAt,
    this.channel = 'unknown',
    this.toolCallId,
    this.argsHash,
    this.expiresAt,
    this.state = ApprovalState.pending,
    this.reason,
    this.decidedAt,
    this.actor,
  });

  final String id;
  final String sessionId;
  final String channel;
  final String tool;
  final String? toolCallId;
  final Map<String, dynamic> args;
  final String? argsHash;
  final String risk;
  final DateTime createdAt;
  final DateTime? expiresAt;
  ApprovalState state;
  String? reason;
  DateTime? decidedAt;
  String? actor;

  bool get isExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);

  Map<String, dynamic> toJson() => {
        'id': id,
        'session_id': sessionId,
        'channel': channel,
        'tool': tool,
        'tool_call_id': toolCallId,
        'args': args,
        'args_hash': argsHash,
        'risk': risk,
        'state': state.name,
        'reason': reason,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt?.toIso8601String(),
        'decided_at': decidedAt?.toIso8601String(),
        'actor': actor,
      };

  factory ApprovalRequest.fromJson(Map<String, dynamic> m) {
    return ApprovalRequest(
      id: m['id'] as String,
      sessionId: m['session_id'] as String,
      channel: m['channel'] as String? ?? 'unknown',
      tool: m['tool'] as String,
      toolCallId: m['tool_call_id'] as String?,
      args: Map<String, dynamic>.from(m['args'] as Map? ?? {}),
      argsHash: m['args_hash'] as String?,
      risk: m['risk'] as String? ?? 'high',
      createdAt: DateTime.parse(m['created_at'] as String).toUtc(),
      expiresAt: m['expires_at'] is String
          ? DateTime.tryParse(m['expires_at'] as String)?.toUtc()
          : null,
      state: ApprovalState.values.firstWhere(
        (s) => s.name == m['state'],
        orElse: () => ApprovalState.pending,
      ),
      reason: m['reason'] as String?,
      decidedAt: m['decided_at'] != null
          ? DateTime.tryParse(m['decided_at'] as String)?.toUtc()
          : null,
      actor: m['actor'] as String?,
    );
  }
}

/// One source of truth for approval creation, waiting, expiry and decisions.
///
/// `decide` is idempotent in the safe direction: only a pending request may be
/// changed. An approval is single-use and expires after [requestTtl].
///
/// All mutations hold the cross-process file lock and re-read the durable
/// ledger before acting, so a CLI process and a daemon sharing the same file
/// cannot overwrite each other's decisions (P0 §7 / Full Repair §6.7).
class ApprovalBroker {
  ApprovalBroker(
    this.path, {
    this.requestTtl = const Duration(minutes: 2),
  });

  final String path;
  final Duration requestTtl;
  final _items = <String, ApprovalRequest>{};
  final _waiters = <String, Completer<bool>>{};
  late final _fileLock = CrossProcessLock(path, timeout: const Duration(seconds: 10));
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void> _saveTail = Future<void>.value();

  /// Serializes a mutation across processes. Re-reads the durable ledger
  /// first so decisions made by another process are visible before acting.
  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    final ticket = await _fileLock.acquire();
    try {
      await _reloadFromDisk();
      return await action();
    } finally {
      await ticket.release();
    }
  }

  /// Concurrent callers share one disk read. Loading never expires pending
  /// items: ordinary CLI/API readers may run beside a live daemon.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _reloadFromDisk().then((_) {
      _loaded = true;
    }).whenComplete(() {
      _loadFuture = null;
    });
  }

  /// Replaces the in-memory view with the durable ledger contents. A corrupt
  /// ledger is never interpreted as an approval: fail closed.
  Future<void> _reloadFromDisk() async {
    final file = File(path);
    if (!await file.exists()) {
      // A directory (or other non-file) at the ledger path is a failed
      // read, not an empty ledger. Keep the in-memory view and fail closed.
      if (await FileSystemEntity.isDirectory(path)) return;
      _items.clear();
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final fresh = <String, ApprovalRequest>{};
      for (final raw in decoded) {
        if (raw is! Map) continue;
        try {
          final item = ApprovalRequest.fromJson(
            Map<String, dynamic>.from(raw),
          );
          fresh[item.id] = item;
        } catch (_) {
          // Ignore one corrupt record without losing the other audit entries.
        }
      }
      _items
        ..clear()
        ..addAll(fresh);
    } catch (_) {
      // Corrupt ledger is not interpreted as an approval. Fail closed.
    }
  }

  /// Called exactly once by a newly locked daemon process. A CLI process that
  /// merely reads the ledger must never invalidate a live daemon's requests.
  Future<void> expirePendingOnStartup() => _withFileLock(() async {
        final now = DateTime.now().toUtc();
        final pending = _items.values
            .where((item) => item.state == ApprovalState.pending)
            .toList();
        if (pending.isEmpty) return;
        for (final item in pending) {
          item.state = ApprovalState.expired;
          item.reason = 'daemon restarted before decision';
          item.decidedAt = now;
          item.actor = 'system';
        }
        try {
          await _save();
        } catch (_) {
          for (final item in pending) {
            item.state = ApprovalState.pending;
            item.reason = null;
            item.decidedAt = null;
            item.actor = null;
          }
          rethrow;
        }
      });

  Future<void> _save() {
    // Serialize mutations; a failed write must not poison later save attempts.
    final operation = _saveTail.catchError((_) {}).then((_) async {
      await File(path).parent.create(recursive: true);
      final values = _items.values.map((e) => e.toJson()).toList();
      final tmp = File('$path.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(values),
        flush: true,
      );
      try {
        // POSIX rename atomically replaces the previous ledger.
        await tmp.rename(path);
      } on FileSystemException {
        // Windows may reject replacement; use a narrow compatibility path.
        final target = File(path);
        if (await target.exists()) await target.delete();
        await tmp.rename(path);
      }
    });
    _saveTail = operation;
    return operation;
  }

  Future<ApprovalRequest> create({
    required Session session,
    required ToolCall call,
    required String risk,
  }) => _withFileLock(() async {
        final now = DateTime.now().toUtc();
        final safeArgs = Map<String, dynamic>.from(call.args)
          ..removeWhere((key, _) => key.startsWith('_'));
        final request = ApprovalRequest(
          id: 'apr_${const Uuid().v4()}',
          sessionId: session.id,
          channel: session.channel,
          tool: call.name,
          toolCallId: call.id,
          args: safeArgs,
          argsHash: _stableHash(safeArgs),
          risk: risk,
          createdAt: now,
          expiresAt: now.add(requestTtl),
        );
        _items[request.id] = request;
        try {
          await _save();
        } catch (_) {
          _items.remove(request.id);
          rethrow;
        }
        return request;
      });

  /// Resolves true only when explicitly approved before expiry.
  ///
  /// While waiting, the durable ledger is polled under a shared lock so a
  /// decision written by another process is honored without waiting for the
  /// full TTL.
  Future<bool> wait(
    String id, {
    Duration? timeout,
  }) async {
    await load();
    // Start from the freshest durable state.
    await _reloadUnderSharedLock();
    final existing = _items[id];
    if (existing == null) return false;
    if (existing.state == ApprovalState.approved) return true;
    if (existing.state != ApprovalState.pending || existing.isExpired) {
      if (existing.state == ApprovalState.pending) {
        await decide(
          id,
          approve: false,
          actor: 'timeout',
          reason: 'approval expired',
        );
      }
      return false;
    }

    final completer = Completer<bool>();
    _waiters[id] = completer;

    final expiresAt = existing.expiresAt;
    final now0 = DateTime.now().toUtc();
    var deadline = now0.add(timeout ?? requestTtl);
    if (expiresAt != null && expiresAt.isBefore(deadline)) deadline = expiresAt;

    const pollEvery = Duration(milliseconds: 800);
    try {
      while (true) {
        final left = deadline.difference(DateTime.now().toUtc());
        if (left <= Duration.zero) {
          await decide(
            id,
            approve: false,
            actor: 'timeout',
            reason: 'approval expired or timed out',
          );
          return false;
        }
        final slice = left < pollEvery ? left : pollEvery;
        // A same-process decision completes the waiter immediately.
        final decided = await completer.future
            .then<bool?>((v) => v)
            .timeout(slice, onTimeout: () => null);
        if (decided != null) return decided;
        // Poll the durable state for decisions made by another process.
        await _reloadUnderSharedLock();
        final item = _items[id];
        if (item == null) return false;
        if (item.state == ApprovalState.approved) return true;
        if (item.state != ApprovalState.pending) return false;
      }
    } finally {
      if (identical(_waiters[id], completer)) _waiters.remove(id);
    }
  }

  /// Only a pending request can be decided. Returns null for an unknown,
  /// expired, or already-decided ID so callers cannot replay an approval.
  ///
  /// The decision is taken under the cross-process file lock against the
  /// freshest durable state, so two processes can never both decide the same
  /// request.
  Future<ApprovalRequest?> decide(
    String id, {
    required bool approve,
    String actor = 'cli',
    String? reason,
  }) => _withFileLock(() async {
        final request = _items[id];
        if (request == null || request.state != ApprovalState.pending) {
          return null;
        }

        final previous = (
          state: request.state,
          reason: request.reason,
          decidedAt: request.decidedAt,
          actor: request.actor,
        );
        final expired = request.isExpired;
        request.state = expired
            ? ApprovalState.expired
            : approve
                ? ApprovalState.approved
                : ApprovalState.denied;
        request.reason = expired ? 'approval expired' : reason;
        request.decidedAt = DateTime.now().toUtc();
        request.actor = expired ? 'system' : actor;
        try {
          await _save();
        } catch (_) {
          request.state = previous.state;
          request.reason = previous.reason;
          request.decidedAt = previous.decidedAt;
          request.actor = previous.actor;
          rethrow;
        }
        _completeWaiter(id, !expired && approve);
        return expired ? null : request;
      });

  /// Re-reads the ledger under a shared (read-only) lock. A short busy-wait is
  /// used when a writer holds the exclusive lock: polling is best-effort.
  Future<void> _reloadUnderSharedLock() async {
    try {
      final ticket = await _fileLock.acquireShared();
      try {
        await _reloadFromDisk();
      } finally {
        await ticket.release();
      }
    } catch (_) {
      // Lock contention or lock failure must not break the wait loop; the
      // next poll or the timeout path still applies.
      await _reloadFromDisk();
    }
  }

  void _completeWaiter(String id, bool decision) {
    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete(decision);
  }

  /// Expires due requests. The caller must already hold the file lock.
  Future<void> _expireDue() async {
    final now = DateTime.now().toUtc();
    final due = _items.values.where((item) =>
        item.state == ApprovalState.pending &&
        item.expiresAt != null &&
        !item.expiresAt!.isAfter(now)).toList();
    if (due.isEmpty) return;

    for (final item in due) {
      item.state = ApprovalState.expired;
      item.reason = 'approval expired';
      item.decidedAt = now;
      item.actor = 'system';
    }
    try {
      await _save();
    } catch (_) {
      // Keep the in-memory state consistent with durable state on write error.
      for (final item in due) {
        item.state = ApprovalState.pending;
        item.reason = null;
        item.decidedAt = null;
        item.actor = null;
      }
      rethrow;
    }
    for (final item in due) {
      _completeWaiter(item.id, false);
    }
  }

  Future<List<ApprovalRequest>> pending() => _withFileLock(() async {
        await _expireDue();
        final now = DateTime.now().toUtc();
        return _items.values
            .where((item) =>
                item.state == ApprovalState.pending &&
                (item.expiresAt == null || item.expiresAt!.isAfter(now)))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });

  Future<List<ApprovalRequest>> all({int limit = 50}) => _withFileLock(() async {
        await _expireDue();
        final list = _items.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list.take(limit).toList();
      });

  Future<void> close() async {
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _waiters.clear();
    await _saveTail.catchError((_) {});
  }

  static String _stableHash(Map<String, dynamic> value) {
    String normalize(dynamic item) {
      if (item is Map) {
        final keys = item.keys.map((e) => '$e').toList()..sort();
        return '{${keys.map((k) => '${jsonEncode(k)}:${normalize(item[k])}').join(',')}}';
      }
      if (item is List) return '[${item.map(normalize).join(',')}]';
      return jsonEncode(item);
    }

    // Hash is an audit fingerprint, not an authentication primitive.
    final input = normalize(value);
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// Backward-compatible name for callers not yet migrated.
typedef ApprovalLedger = ApprovalBroker;
