import 'dart:async';
import 'dart:io';

/// Cross-process advisory lock (FR hardening — multi-process safety).
///
/// Serializes ledger/queue mutations between independent OS processes that
/// share one data file (for example a CLI chat process and a running daemon).
///
/// The primitive is an **exclusive file create** (`File.create(exclusive:
/// true)`, O_EXCL): only one acquirer can create the lock file; every other
/// acquirer's create throws and retries. A plain `Directory.create` cannot be
/// used here — it is idempotent and silently succeeds on an existing path,
/// which would let two holders in at once.
///
/// A holder that crashes without releasing leaves its lock file behind; it
/// is reclaimed automatically once it is older than [staleAfter].
class CrossProcessLock {
  CrossProcessLock(
    this.targetPath, {
    this.timeout = const Duration(seconds: 10),
    this.staleAfter = const Duration(minutes: 5),
  });

  /// Path of the data file being protected. The lock file is
  /// `<targetPath>.lock`.
  final String targetPath;

  /// How long [acquire] waits before giving up.
  final Duration timeout;

  /// A holder that crashed without releasing keeps its lock file on disk;
  /// once older than this the lock is considered abandoned and the next
  /// acquirer reclaims it.
  final Duration staleAfter;

  String get _lockPath => '$targetPath.lock';

  /// Takes the exclusive lock, polling briefly until free or timed out.
  Future<LockTicket> acquire() => _take();

  /// Coordinated readers serialize through the same lock: the protected
  /// files are small, so mutation safety outweighs read fan-out.
  Future<LockTicket> acquireShared() => _take();

  Future<LockTicket> _take() async {
    final lockFile = File(_lockPath);
    await lockFile.parent.create(recursive: true);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        await lockFile.create(exclusive: true);
        return _Ticket(lockFile);
      } on FileSystemException {
        // Already held: reclaim it when the previous holder died long ago.
        if (await _isStale(lockFile)) {
          await _removeQuietly(lockFile);
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

  Future<bool> _isStale(File lockFile) async {
    try {
      final modified = await lockFile.stat();
      return DateTime.now().isAfter(modified.modified.add(staleAfter));
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeQuietly(File lockFile) async {
    try {
      await lockFile.delete();
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
  _Ticket(this._lockFile);

  final File _lockFile;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _lockFile.delete();
    } catch (_) {
      // The file was already reclaimed as stale or deleted by a peer;
      // either way the lock is no longer ours.
    }
  }
}
