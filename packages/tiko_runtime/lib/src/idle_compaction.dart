part of 'tiko_runtime.dart';

/// Hermes `170d9637` (gateway idle compaction on every route, per channel):
/// sesi yang menganggur melewati ambang idle dikompaksi DI LATAR sehingga
/// pesan pertama user setelah idle panjang tidak menunggu ringkasan.
/// Deviasi sadar dari Hermes:
/// - Hermes memakai housekeeping tick gateway dengan cache-edge claim +
///   semaphore bersama + lease/fence pipeline manual-compression; Tiko
///   memakai [Timer.periodic] tunggal di runtime (single-isolate) dengan
///   gate serial per tick + latch per sesi (semantik claim ekuivalen).
/// - Gate admission Hermes (`idle_compaction_admission`: di atas floor
///   pasca-kompaksi, tumbuh sejak kompaksi terakhir, tanpa cooldown) Tiko
///   terjemahkan jadi gate riwayat di jalur kompaksi runtime
///   ([TikoRuntime._compactSessionCore]): min pesan + min estimasi token.
/// - Latch mengikuti Hermes: percobaan (sukses maupun gagal) melatch pada
///   `updatedAt` sesi — tidak diulang sampai ada aktivitas baru.
/// - Skip sesi yang sedang menjalankan turn (`SessionLock`) dan channel
///   dengan override `0` (off per channel, semantik Hermes).
/// - Default `enabled: false` (deviasi dari Hermes yang fail-open) —
///   panggilan LLM latar berbiaya; diaktifkan eksplisit di config.
/// - Never-raises: kegagalan store/LLM hanya event `compaction.idle`
///   ber-`outcome: failed`, tick berikutnya tetap jalan.
class IdleCompactionEngine {
  IdleCompactionEngine({
    required this.config,
    required this.events,
    required this.sessions,
    required this.busyOf,
    required this.compactOf,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final IdleCompactionConfig config;
  final EventBus events;
  final SessionStore sessions;

  /// True bila sesi sedang menjalankan turn (skip, jangan latch).
  final bool Function(String sessionId) busyOf;

  /// Pipeline kompaksi persist (sama dengan `/compact`); false bila
  /// tidak layak/gagal. Channel/userKey dari metadata sesi.
  final Future<bool> Function(
    String sessionId, {
    required String channel,
    required String userKey,
  }) compactOf;

  final DateTime Function() _clock;

  Timer? _timer;
  bool _ticking = false;
  bool _closed = false;

  /// Latch per sesi: timestamp aktivitas terakhir saat percobaan terakhir.
  /// Sesi jadi layak lagi hanya bila `updatedAt` lebih baru dari latch.
  final Map<String, DateTime> _latched = {};

  int ticks = 0;
  int attempted = 0;
  int compacted = 0;
  int failed = 0;

  /// Batas FIFO state latch per-sesi (konvensi runtime: 500 entri).
  static const maxTrackedSessions = 500;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(
      Duration(seconds: config.tickSec.clamp(5, 3600)),
      (_) => unawaited(_tick()),
    );
  }

  /// Ambang idle efektif satu channel: override channel bila ada,
  /// selain itu ambang global. 0 berarti off untuk channel itu.
  int thresholdFor(String channel) =>
      config.channelOverrides[channel] ?? config.afterSec;

  /// Jalankan satu housekeeping tick sekarang (dipakai pengujian dan
  /// pemicu manual); aman dipanggil kapan pun — tick ganda di-skip.
  Future<void> runTick() => _tick();

  Future<void> _tick() async {
    if (_ticking || _closed || !config.enabled || config.afterSec <= 0) return;
    _ticking = true;
    try {
      ticks++;
      final now = _clock().toUtc();
      final List<SessionInfo> infos;
      try {
        infos = await sessions.list();
      } catch (_) {
        return;
      }
      for (final info in infos) {
        final thresholdSec = thresholdFor(info.channel);
        if (thresholdSec <= 0) continue;
        final updatedAt = info.updatedAt.toUtc();
        final idle = now.difference(updatedAt);
        if (idle < Duration(seconds: thresholdSec)) continue;
        final latched = _latched[info.id];
        if (latched != null && !updatedAt.isAfter(latched)) continue;
        if (busyOf(info.id)) continue;
        _evictLatched();
        _latched[info.id] = updatedAt;
        attempted++;
        var ok = false;
        try {
          ok = await compactOf(
            info.id,
            channel: info.channel,
            userKey: info.userKey,
          );
        } catch (_) {}
        if (ok) {
          compacted++;
        } else {
          failed++;
        }
        events.emit('compaction.idle', {
          'session': info.id,
          'channel': info.channel,
          'outcome': ok ? 'compacted' : 'failed',
          'idle_sec': idle.inSeconds,
        });
      }
    } catch (_) {
      // Never-raises: housekeeping tidak pernah menjatuhkan runtime.
    } finally {
      _ticking = false;
    }
  }

  void _evictLatched() {
    while (_latched.length >= maxTrackedSessions) {
      _latched.remove(_latched.keys.first);
    }
  }

  Map<String, dynamic> snapshot() => {
        'enabled': config.enabled,
        'after_sec': config.afterSec,
        'tick_sec': config.tickSec,
        'channel_overrides': config.channelOverrides,
        'ticks': ticks,
        'attempted': attempted,
        'compacted': compacted,
        'failed': failed,
        'latched': _latched.length,
      };

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
