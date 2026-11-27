// Hermes parity: `agent/iteration_budget.py` — budget iterasi per-agent.
//
// Satu `IterationBudget` per entitas (loop utama atau subagent): parent
// memakai cap `maxIterations`, subagent cap delegasinya sendiri, sehingga
// total iterasi lintas entitas bisa melebihi cap parent tanpa kehilangan
// batas per entitas. Counter thread-safe (single-isolate Dart: lock tidak
// diperlukan, tapi semua mutasi tetap lewat method agar invariant terjaga).
//
// `execute_code` (programmatic tool calling) di-refund lewat [refund]
// supaya tidak memakan budget — Hermes mensyaratkan refund hanya untuk
// iterasi yang benar-benar tidak menghasilkan progres eksternal.

/// Rasio peringatan budget yang valid: finite dan 0 < r < 1, selain itu
/// null (fitur off). Menerima bool/string/NaN/Inf tanpa melempar.
double? normalizeIterationWarnRatio(Object? value) {
  if (value == null || value is bool) return null;
  final ratio = value is num
      ? value.toDouble()
      : double.tryParse('$value');
  if (ratio == null) return null;
  if (!ratio.isFinite) return null;
  return (ratio > 0 && ratio < 1) ? ratio : null;
}

/// Budget iterasi consume/refund per-agent (Hermes `iteration_budget.py`).
class IterationBudget {
  IterationBudget({required this.maxTotal, this.warnRatio});

  /// Cap total iterasi untuk entitas ini.
  final int maxTotal;

  /// Rasio (0,1) yang memicu [nearLimit]; null = peringatan off.
  final double? warnRatio;

  int _used = 0;

  /// Coba konsumsi satu iterasi. True bila masih di bawah cap.
  bool consume() {
    if (_used >= maxTotal) return false;
    _used += 1;
    return true;
  }

  /// Kembalikan satu iterasi (mis. turn programmatic yang tidak memakan
  /// progres). Tidak pernah negatif.
  void refund() {
    if (_used > 0) _used -= 1;
  }

  int get used => _used;

  int get remaining => maxTotal > _used ? maxTotal - _used : 0;

  /// True bila warnRatio aktif dan sisa iterasi sudah di bawah
  /// porsi peringatan dari cap.
  bool get nearLimit {
    final ratio = warnRatio;
    if (ratio == null || maxTotal <= 0) return false;
    return remaining <= (maxTotal * ratio).floor() && remaining > 0;
  }
}
