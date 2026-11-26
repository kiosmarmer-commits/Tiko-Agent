/// Empty response guard (Hermes `agent/empty_response_guard.py`): deteksi
/// jawaban kosong *tidak tersinyal* — finishReason sukses, nol output, tanpa
/// tool call (khas refusal yang diproxy portal tanpa penanda) — dan budget
/// retry sadar-biaya.
///
/// Dua guard, keduanya fail-open ke perilaku lama:
/// 1. Deterministic-empty: dua attempt kosong berturut-turut dengan
///    signature (model, provider, finishReason) sama dan usage membuktikan
///    nol output (atau tanpa usage dan tanpa konten teream) → lewati sisa
///    retry, langsung ke fallback chain (model lain mungkin berbeda).
/// 2. Budget sadar-biaya: satu attempt kosong yang estimasi biayanya ≥
///    threshold memangkas budget retry 3 → 1. Harga tak dikenal tidak
///    mengubah budget.
class EmptyAttempt {
  const EmptyAttempt({
    required this.model,
    required this.provider,
    required this.finishReason,
    required this.usagePresent,
    required this.zeroOutput,
    required this.observedGeneration,
    this.estimatedCostUsd,
  });

  final String model;
  final String provider;
  final String finishReason;
  final bool usagePresent;
  final bool zeroOutput;
  final bool observedGeneration;

  /// Estimasi biaya attempt ini (USD) — null bila harga tak dikenal.
  final double? estimatedCostUsd;

  (String, String, String) get signature =>
      (model, provider, finishReason);
}

class EmptyGuardSettings {
  const EmptyGuardSettings({
    this.enabled = true,
    this.costThresholdUsd = 0.25,
  });

  final bool enabled;
  final double costThresholdUsd;
}

class EmptyResponseGuard {
  EmptyResponseGuard({EmptyGuardSettings? settings})
      : settings = settings ?? const EmptyGuardSettings();

  static const defaultRetryBudget = 3;
  static const reducedRetryBudget = 1;

  final EmptyGuardSettings settings;

  final List<EmptyAttempt> _attempts = [];
  double _streakCostUsd = 0;

  int get attempts => _attempts.length;
  double? get streakCostUsd => _streakCostUsd > 0 ? _streakCostUsd : null;

  /// Reset streak — dipanggil di awal turn, setelah kompresi, sukses tool,
  /// atau aktivasi fallback.
  void reset() {
    _attempts.clear();
    _streakCostUsd = 0;
  }

  /// Catat satu jawaban kosong dalam streak berjalan.
  void recordAttempt({
    required String model,
    required String provider,
    required String finishReason,
    bool usagePresent = false,
    bool zeroOutput = false,
    bool observedGeneration = true,
    double? estimatedCostUsd,
  }) {
    final a = EmptyAttempt(
      model: model,
      provider: provider,
      finishReason: finishReason,
      usagePresent: usagePresent,
      zeroOutput: zeroOutput,
      observedGeneration: observedGeneration,
      estimatedCostUsd: estimatedCostUsd,
    );
    _attempts.add(a);
    final cost = a.estimatedCostUsd;
    if (cost != null && cost > 0) _streakCostUsd += cost;
  }

  /// True bila streak terlihat deterministik: ≥ 2 attempt dengan signature
  /// identik dan semua bukti menyatakan kosong. Bukti campuran fail-open.
  bool get deterministicEmpty {
    if (!settings.enabled) return false;
    if (_attempts.length < 2) return false;
    final first = _attempts.first.signature;
    final sameSignature = _attempts.every((a) => a.signature == first);
    final usageProvesEmpty =
        _attempts.every((a) => a.usagePresent && a.zeroOutput);
    final responseProvesEmpty =
        _attempts.every((a) => !a.usagePresent && !a.observedGeneration);
    return sameSignature && (usageProvesEmpty || responseProvesEmpty);
  }

  /// Budget retry jawaban kosong untuk streak berjalan: 3, atau 1 bila satu
  /// attempt terakhir terbukti mahal melewati threshold.
  int retryBudget({double? lastAttemptCostUsd}) {
    if (!settings.enabled) return defaultRetryBudget;
    final cost = lastAttemptCostUsd;
    if (cost != null && cost >= settings.costThresholdUsd) {
      return reducedRetryBudget;
    }
    return defaultRetryBudget;
  }
}
