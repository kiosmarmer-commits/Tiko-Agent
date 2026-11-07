import 'dart:async';
import 'dart:io';

/// Cross-process advisory file lock (FR hardening — multi-process safety).
///
/// Serializes ledger/queue mutations between independent OS processes that
/// share one data file (for example a CLI chat process and a running daemon).
/// The lock is an OS-level advisory lock on a sidecar `.lock` file:
///
/// * POSIX: advisory `flock`-style lock — every participant must take the
///   lock for the protocol to hold.
/// * Windows: mandatory byte-range lock semantics.
///
/// [acquire] fails with a [TimeoutException] instead of hanging forever, so a
/// wedged peer cannot freeze the runtime: callers already treat mutation
/// failures as fail-closed and revert their in-memory state.
class CrossProcessLock {
  CrossProcessLock(this.targetPath, {this.timeout = const Duration(seconds: 10)});

  /// Path of the data file being protected. The lock file is
  /// `<targetPath>.lock`.
  final String targetPath;

  /// How long [acquire] waits before giving up.
  final Duration timeout;

  String get _lockPath => '$targetPath.lock';

  /// Takes the exclusive lock, polling briefly until free or timed out.
  Future<LockTicket> acquire() => _take(FileLock.exclusive);

  /// Takes a shared lock for read-only coordinated access.
  Future<LockTicket> acquireShared() => _take(FileLock.shared);

  Future<LockTicket> _take(FileLock mode) async {
    final lockFile = File(_lockPath);
    await lockFile.parent.create(recursive: true);
    final raf = await lockFile.open(mode: FileMode.append);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await raf.tryLock(mode)) return _Ticket(raf);
      if (DateTime.now().isAfter(deadline)) {
        try {
          await raf.close();
        } catch (_) {}
        throw TimeoutException(
          'cross-process lock timeout: $_lockPath',
          timeout,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}

/// A held lock. Exactly one [release] must be called — always from a
/// `finally` block.
abstract class LockTicket {
  Future<void> release();
}

class _Ticket implements LockTicket {
  _Ticket(this._raf);

  final RandomAccessFile _raf;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _raf.unlock();
    } catch (_) {
      // The descriptor may already be closed by the OS; release is done.
    }
    try {
      await _raf.close();
    } catch (_) {}
  }
}
