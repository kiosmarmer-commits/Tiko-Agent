/// Cap lifetime total satu attempt streaming (Hermes `agent/stream_max_lifetime.py`):
/// detektor stale stream membatasi JEDA ANTARA chunk dan reset di setiap
/// chunk, sehingga stream yang terus mengirim data tapi tak pernah selesai
/// (gateway meneteskan chunk, generasi runaway) tidak pernah dipotong.
/// Cap wall-clock sejak attempt dimulai; TIDAK reset saat chunk tiba.
/// Default 0 = off — stream reasoning yang sah tidak pernah dipotong kecuali
/// diminta.
library;

/// Cap dalam detik, 0 bila disabled. Difloor pada stale timeout yang finite
/// agar cap tidak pernah memotong stream yang masih ditunggu detektor stale.
double resolveStreamMaxLifetime(
  double? configuredValue,
  double? staleTimeout,
) {
  if (configuredValue == null ||
      configuredValue <= 0 ||
      configuredValue.isNaN ||
      configuredValue.isInfinite) {
    return 0.0;
  }
  if (staleTimeout != null &&
      !staleTimeout.isNaN &&
      !staleTimeout.isInfinite) {
    return configuredValue > staleTimeout ? configuredValue : staleTimeout;
  }
  return configuredValue;
}

/// Pesan user-facing saat stream dipotong cap — menyebut setting, bukan
/// endpoint, karena stream terbuka dan masih mengirim chunk.
String streamLifetimeExceededMessage(double elapsed, double cap) =>
    'Respons masih streaming setelah ${elapsed.toStringAsFixed(0)}s, '
    'dipotong oleh agent.stream_max_lifetime '
    '(${_fmtCap(cap)}s). Naikkan agent.stream_max_lifetime, atau set 0 '
    'untuk mematikan cap, bila model ini memang legitimately streaming '
    'selama itu.';

String _fmtCap(double cap) => cap == cap.roundToDouble()
    ? cap.toStringAsFixed(0)
    : cap.toStringAsFixed(2);

/// Clock per-call: restart tiap attempt stream baru, sehingga tiap retry
/// mendapat cap penuh, dan setelah tiap kill (attempt terkill mungkin unwind
/// lambat).
class StreamLifetime {
  StreamLifetime({required this.cap, double Function()? clock})
      : _clock = clock ?? (() => DateTime.now().microsecondsSinceEpoch / 1e6);

  /// Cap detik; 0 = disabled.
  final double cap;
  final double Function() _clock;
  int? _attempt;
  double _started = 0;

  /// Detik berlalu saat cap terlampaui untuk [attempt], else null.
  /// Attempt berbeda me-restart pengukuran (cap penuh per attempt).
  double? exceeded(int attempt) {
    if (cap <= 0) return null;
    final now = _clock();
    if (attempt != _attempt) {
      _attempt = attempt;
      _started = now;
      return null;
    }
    final elapsed = now - _started;
    if (elapsed <= cap) return null;
    _started = now;
    return elapsed;
  }
}
