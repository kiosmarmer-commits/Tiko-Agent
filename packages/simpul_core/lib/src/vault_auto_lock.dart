import 'dart:async';

/// Idle auto-lock for long-lived processes (SEC-16): after [idleTimeout]
/// without [touch], [onLock] fires once so the host can wipe derived key
/// material (see `VaultCrypto.wipe`). The timer rearms on the next [touch].
///
/// Short-lived CLI processes already release keys at exit; this utility is
/// for the MCP bridge and any future UI layer holding a [VaultCrypto].
class VaultAutoLock {
  VaultAutoLock({
    required this.onLock,
    this.idleTimeout = const Duration(minutes: 10),
  });

  final void Function() onLock;
  final Duration idleTimeout;

  Timer? _timer;
  int _epoch = 0;

  /// True while a lock timer is armed.
  bool get isArmed => _timer != null;

  /// Records activity and rearms the timer. A stale timer from a previous
  /// touch never fires (epoch guard).
  void touch() {
    _timer?.cancel();
    final epoch = ++_epoch;
    _timer = Timer(idleTimeout, () {
      if (epoch != _epoch) return;
      _timer = null;
      onLock();
    });
  }

  /// Disarms without firing.
  void stop() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
