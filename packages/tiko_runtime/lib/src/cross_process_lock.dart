import 'dart:async';
import 'dart:io';

/// Cross-process advisory lock (FR hardening — multi-process safety).
///
/// Serializes ledger/queue mutations between independent OS processes that
/// share one data file (for example a CLI chat process and a running daemon).
///
/// [RandomAccessFile.tryLock] is unavailable on several Dart platform builds,
/// so the lock primitive here is an **atomic directory create**: only one
/// process can create the directory at a time on every OS Dart supports.
/// A holder that crashes without releasing leaves its directory behind; it
/// is reclaimed automatically once it is older than [staleAfter].
class CrossProcessLock {
  CrossProcessLock(
    this.targetPath, {
    this.timeout = const Duration(seconds: 10),
    this.staleAfter = const Duration(minutes: 5),
  });

  /// Path of the data file being protected. The lock directory is
  /// `<targetPath>.lock`.
  final String targetPath;

  /// How long [acquire] waits before giving up.
  final Duration timeout;

  /// A holder that crashed without releasing keeps its lock directory on
  /// disk; once older than this the lock is considered abandoned and the
  /// next acquirer reclaims it.
  final Duration staleAfter;

  String get _lockPath => '$targetPath.lock';

  /// Takes the exclusive lock, polling briefly until free or timed out.
  Future<LockTicket> acquire() => _take();

  /// Coordinated readers serialize through the same lock: the protected
  /// files are small, so mutation safety outweighs read fan-out.
  Future<LockTicket> acquireShared() => _take();

  Future<LockTicket> _take() async {
    final lockDir = Directory(_lockPath);
    await lockDir.parent.create(recursive: true);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        await lockDir.create(recursive: false);
        return _Ticket(lockDir);
      } on FileSystemException {
        // Already held: reclaim it when the previous holder died long ago.
        if (await _isStale(lockDir)) {
          await _removeQuietly(lockDir);
          continue;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'cross-process lock timeout: $_lockPath',
          timeout,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<bool> _isStale(Directory lockDir) async {
    try {
      final modified = await lockDir.stat();
      return DateTime.now().isAfter(modified.modified.add(staleAfter));
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeQuietly(Directory lockDir) async {
    try {
      await lockDir.delete(recursive: true);
    } catch (_) {
      // Another process reclaimed it first; the next loop retries create().
    }
  }
}

/// A held lock. Exactly one [release] must be called — always from a
/// `finally` block.
abstract class LockTicket {
  Future<void> release();
}

class _Ticket implements LockTicket {
  _Ticket(this._lockDir);

  final Directory _lockDir;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _lockDir.delete(recursive: true);
    } catch (_) {
      // The directory was already reclaimed as stale or deleted by a peer;
      // either way the lock is no longer ours.
    }
  }
}
