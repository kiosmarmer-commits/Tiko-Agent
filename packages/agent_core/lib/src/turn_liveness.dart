// Hermes parity: `agent/turn_liveness.py` — watchdog liveness turn.
//
// Sebuah turn bisa macet di tengah jalan tanpa error sama sekali (stream
// provider berhenti mengirim event, lease masih terlihat hidup), sehingga
// sesi tidak pernah dibebaskan. Watchdog mengukur waktu idle SEJAK AKTIVITAS
// TERAKHIR (bukan wall-clock total — itu tugas maxWallClockSec/stream
// max-lifetime) dan memaksa abort ketika tidak ada progres melewati batas.
//
// Race safety (port semantik #95548): keputusan abort diikat pada
// `(generation, activityTs)` yang diamati; commit callback memvalidasi ulang
// di bawah lock yang sama yang dipakai [ActivityClock.stamp], jadi turn yang
// justru bangun kembali tidak pernah di-cancel.

import 'dart:async';

/// Durasi default tanpa progres sebelum turn dianggap macet
/// (Hermes `DEFAULT_TURN_LIVENESS_TIMEOUT_S`).
const double defaultTurnLivenessTimeoutS = 600.0;

/// Interval sampling default watchdog (Hermes `DEFAULT_TURN_LIVENESS_POLL_S`).
const double defaultTurnLivenessPollS = 15.0;

/// Poll minimum yang diizinkan (anti busy-loop).
const double minTurnLivenessPollS = 0.01;

/// Kode error LLM khusus bila stream di-abort watchdog liveness — dipakai
/// [AgentLoop] untuk membedakan abort liveness dari error provider biasa
/// (liveness TIDAK diikuti fallback chain; sesi dibebaskan).
const String llmErrorCodeTurnLiveness = 'turn_liveness';

/// Alasan akhir turn untuk observability host.
const String turnEndReasonLivenessAbort = 'liveness_abort';

/// Pesan user-facing saat watchdog meng-abort turn yang macet.
String turnLivenessAbortMessage(int idleSec) =>
    '⚠️ Turn berhenti membuat progres ($idleSec detik tanpa aktivitas); '
    'turn di-abort agar sesi bisa lanjut. Silakan kirim ulang pesan Anda.';

/// Koersisi satu knob durasi, menolak typo/NaN/Inf (never raises).
/// NaN akan mematikan timeout lewat perbandingan `> 0` dan Inf membekukan
/// loop poll di `Event.wait` — keduanya di-fallback ke default.
double _resolveFiniteSeconds(
  Object? raw, {
  required double defaultSec,
  required String key,
  void Function(String key, Object? raw, double defaultSec)? onInvalid,
}) {
  double value;
  if (raw is num) {
    value = raw.toDouble();
  } else {
    value = double.tryParse('$raw') ?? double.nan;
  }
  if (!value.isFinite) {
    onInvalid?.call(key, raw, defaultSec);
    return defaultSec;
  }
  return value;
}

/// Resolusi `(timeoutS, pollS)` dari section `agent.turn_liveness`.
/// Nilai tidak valid (typo, NaN, Inf, poll <= 0) di-fallback ke default
/// dengan peringatan via [onInvalid] — never raises.
TurnLivenessSettings resolveTurnLivenessSettings(
  Map<String, dynamic>? config, {
  void Function(String key, Object? raw, double defaultSec)? onInvalid,
}) {
  var timeoutS = defaultTurnLivenessTimeoutS;
  var pollS = defaultTurnLivenessPollS;
  final agentCfg = config?['agent'];
  final section = agentCfg is Map<String, dynamic>
      ? agentCfg['turn_liveness']
      : null;
  if (section != null && section is! Map<String, dynamic>) {
    onInvalid?.call('agent.turn_liveness', section, defaultTurnLivenessTimeoutS);
  }
  final map = section is Map<String, dynamic> ? section : const {};
  timeoutS = _resolveFiniteSeconds(
    map['timeout_s'] ?? defaultTurnLivenessTimeoutS,
    defaultSec: defaultTurnLivenessTimeoutS,
    key: 'agent.turn_liveness.timeout_s',
    onInvalid: onInvalid,
  );
  pollS = _resolveFiniteSeconds(
    map['poll_s'] ?? defaultTurnLivenessPollS,
    defaultSec: defaultTurnLivenessPollS,
    key: 'agent.turn_liveness.poll_s',
    onInvalid: onInvalid,
  );
  if (pollS <= 0 || pollS < minTurnLivenessPollS) {
    onInvalid?.call(
      'agent.turn_liveness.poll_s', pollS, defaultTurnLivenessPollS);
    pollS = defaultTurnLivenessPollS;
  }
  if (timeoutS <= 0) timeoutS = 0;
  return TurnLivenessSettings(timeoutS: timeoutS, pollS: pollS);
}

/// Hasil resolusi konfigurasi turn-liveness. `timeoutS == 0` = off.
class TurnLivenessSettings {
  const TurnLivenessSettings({required this.timeoutS, required this.pollS});

  final double timeoutS;
  final double pollS;

  bool get enabled => timeoutS > 0;
}

/// Satu observasi jam aktivitas; `(generation, activityTs)` wajib
/// divalidasi ulang oleh commit callback di bawah lock yang sama.
class ActivitySnapshot {
  const ActivitySnapshot({
    required this.generation,
    required this.activityTs,
    required this.idleSeconds,
  });

  final int generation;
  final DateTime? activityTs;
  final double idleSeconds;
}

/// Jam aktivitas bersama: turn yang hidup men-stamp tiap kali ada progres
/// (delta teks, tool call, tool selesai). Watchdog membaca tanpa mengubah.
class ActivityClock {
  DateTime? _lastActivity;
  int _generation = 0;
  final List<void Function(ActivitySnapshot)> _stamps = [];

  /// Stamp progres SEKARANG. Menambah generation, sehingga abort yang
  /// terikat pada snapshot lama dinyatakan basi saat revalidasi.
  void stamp([String? desc]) {
    _lastActivity = DateTime.now().toUtc();
    _generation += 1;
    final snapshot = ActivitySnapshot(
      generation: _generation,
      activityTs: _lastActivity,
      idleSeconds: 0,
    );
    for (final listener in List.of(_stamps)) {
      try {
        listener(snapshot);
      } catch (_) {} // listener tidak boleh menggagalkan stamp
    }
  }

  /// Validasi ulang snapshot: hanya masih relevan bila generation dan
  /// timestamp-nya sama dengan yang terlihat watchdog.
  bool revalidate(ActivitySnapshot snapshot) =>
      snapshot.generation == _generation &&
      snapshot.activityTs == _lastActivity;

  ActivitySnapshot sample() {
    final last = _lastActivity;
    final idle = last == null
        ? 0.0
        : DateTime.now().toUtc().difference(last).inMilliseconds / 1000.0;
    return ActivitySnapshot(
      generation: _generation,
      activityTs: last,
      idleSeconds: idle < 0 ? 0 : idle,
    );
  }

  void addStampListener(void Function(ActivitySnapshot) listener) =>
      _stamps.add(listener);
}

/// Watchdog liveness turn (Hermes `turn_liveness.py`): polling berkala
/// via [Timer.periodic]; ketika idle > timeout dan commit callback
/// menyetujui (turn masih aktif setelah revalidasi), [onAbort] dipanggil
/// sekali lalu watchdog berhenti sendiri.
class TurnLivenessWatchdog {
  TurnLivenessWatchdog({
    required this.clock,
    required this.timeoutS,
    double? pollS,
    required this.isTurnActive,
    required this.commitAbort,
  }) : pollS = (pollS ?? defaultTurnLivenessPollS) < minTurnLivenessPollS
            ? minTurnLivenessPollS
            : (pollS ?? defaultTurnLivenessPollS);

  /// Jam aktivitas yang di-stamp jalannya turn.
  final ActivityClock clock;

  /// Batas idle dalam detik; <= 0 mematikan watchdog.
  final double timeoutS;

  /// Interval sampling dalam detik.
  final double pollS;

  /// Turn masih aktif (belum selesai/di-cancel pemanggil)?
  final bool Function() isTurnActive;

  /// Commit abort: dipanggil dengan snapshot yang sudah melewati batas.
  /// Harus me-revalidasi snapshot lewat [ActivityClock.revalidate] dan
  /// mengembalikan false bila ternyata turn sudah bangun kembali.
  final bool Function(ActivitySnapshot snapshot, String message) commitAbort;

  Timer? _timer;
  bool _aborted = false;
  int _lastSurfacedGeneration = -1;

  /// Mulai polling. Idempotent: panggilan kedua diabaikan.
  void start() {
    if (_timer != null || timeoutS <= 0) return;
    _timer = Timer.periodic(
      Duration(milliseconds: (pollS * 1000).round()),
      (_) => _tick(),
    );
  }

  /// Satu poll. False berarti watchdog selesai.
  bool _tick() {
    if (_aborted || !isTurnActive()) {
      stop();
      return false;
    }
    final snapshot = clock.sample();
    if (snapshot.idleSeconds < timeoutS) return true;
    // Observational-only: commit bisa mem-veto bila ternyata turn bangun.
    if (_lastSurfacedGeneration != snapshot.generation) {
      _lastSurfacedGeneration = snapshot.generation;
    }
    final message =
        'Turn tidak membuat progres ${snapshot.idleSeconds.toStringAsFixed(0)}s; '
        'meng-abort untuk membebaskan sesi.';
    if (!commitAbort(snapshot, message)) return true;
    _aborted = true;
    stop();
    return false;
  }

  /// Hentikan polling. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  bool get aborted => _aborted;
}
