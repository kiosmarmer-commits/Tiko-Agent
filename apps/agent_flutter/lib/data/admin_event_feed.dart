import 'dart:async';

/// Live push WS admin feed: dengarkan event runtime dari
/// `AgentApiClient.streamEvents()` dan picu refresh admin dengan debounce
/// agar burst event tidak membanjiri backend. Koneksi yang rusak/putus
/// diputar ulang otomatis dengan backoff (2s berlipat sampai 60s);
/// polling 15 detik di [main] tetap dipertahankan sebagai fallback.
class AdminEventFeed {
  AdminEventFeed({
    required this.events,
    required this.onRefresh,
    this.debounce = const Duration(seconds: 1),
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 60),
  });

  final Stream<Map<String, dynamic>> events;
  final Future<void> Function() onRefresh;
  final Duration debounce;
  final Duration baseDelay;
  final Duration maxDelay;

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _debounce;
  Timer? _retry;
  Duration _retryDelay = Duration.zero;
  int received = 0;

  ///Refresh yang sudah dijadwalkan tapi belum dijalankan (untuk test).
  bool get pendingRefresh => _debounce != null;

  ///Backoff reconnect berikutnya yang dijadwalkan (untuk test).
  Duration get nextRetryDelay => _retryDelay;

  void start() {
    _sub = events.listen(
      _onEvent,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
  }

  void _onEvent(Map<String, dynamic> event) {
    received++;
    _retryDelay = Duration.zero;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => onRefresh());
  }

  void _scheduleReconnect() {
    _debounce?.cancel();
    _debounce = null;
    unawaited(_sub?.cancel());
    _sub = null;
    if (_retry != null) return;
    _retryDelay =
        _retryDelay == Duration.zero ? baseDelay : _retryDelay * 2;
    if (_retryDelay > maxDelay) _retryDelay = maxDelay;
    _retry = Timer(_retryDelay, () {
      _retry = null;
      start();
    });
  }

  void dispose() {
    _debounce?.cancel();
    _retry?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
  }
}
