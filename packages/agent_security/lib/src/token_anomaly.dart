library;

import 'dart:math';

/// Deteksi anomali token per skill (E1, "immune-lite").
///
/// Setiap giliran (turn) yang memakai sebuah skill dicatat total token-nya
/// per skill. Dari sampel historis dibangun baseline statistik rolling
/// (rata-rata + simpangan baku). Bila pemakaian token terbaru melonjak
/// jauh melampaui baseline, skill ditandai anomali agar host runtime bisa
/// menindaklanjuti (audit, event, karantina ke draft).
///
/// Batasan yang jujur (BUKAN "agen imun otonom"):
/// - Ini detektor ambang statistik sederhana (mean + z*stddev dengan
///   lantai rasio minimum), bukan model pembelajaran.
/// - Token giliran diatribusikan utuh ke setiap skill yang dipakai pada
///   giliran itu — bisa dobel hitung antar skill; pendekatan konservatif.
/// - Detektor hanya MELAPORKAN. Penindakan (karantina, persetujuan) ada di
///   tiko_runtime, mengikuti mekanisme yang sudah ada (status draft +
///   audit log), dengan cap harian agar tidak berisik.
class TokenAnomalyDetector {
  TokenAnomalyDetector({
    this.minSamples = 5,
    this.windowSize = 50,
    this.zMultiplier = 3.0,
    this.minSpikeRatio = 3.0,
    this.cooldown = const Duration(minutes: 60),
  })  : assert(minSamples >= 2, 'minSamples minimal 2'),
        assert(windowSize >= minSamples,
            'windowSize harus >= minSamples'),
        assert(zMultiplier > 0, 'zMultiplier harus positif'),
        assert(minSpikeRatio >= 1.0, 'minSpikeRatio minimal 1.0');

  /// Jumlah sampel minimum sebelum anomali bisa terdeteksi — sebelum itu
  /// baseline belum bermakna (fail-closed: tidak ada alarm prematur).
  final int minSamples;

  /// Ukuran jendela rolling per skill (FIFO).
  final int windowSize;

  /// Ambang z-score: tokens > mean + zMultiplier * stddev.
  final double zMultiplier;

  /// Lantai rasio: tokens >= mean * minSpikeRatio. Melindungi dari baseline
  /// datar (stddev ~ 0) yang membuat z-score meledak untuk lonjakan kecil.
  final double minSpikeRatio;

  /// Jeda minimum antar alarm untuk skill yang sama (anti-spam).
  final Duration cooldown;

  final Map<String, List<int>> _samples = {};
  final Map<String, DateTime> _lastAlert = {};

  /// Catat pemakaian token [tokens] untuk skill [slug] pada saat [now],
  /// lalu kembalikan [TokenAnomaly] bila nilai ini adalah lonjakan,
  /// atau null bila normal / baseline belum cukup / masih cooldown.
  ///
  /// Sampel yang memicu alarm TETAP dicatat (baseline ikut bergerak).
  TokenAnomaly? observe(String slug, int tokens, DateTime now) {
    if (slug.isEmpty || tokens < 0) return null;
    final list = _samples.putIfAbsent(slug, () => <int>[]);
    list.add(tokens);
    while (list.length > windowSize) {
      list.removeAt(0);
    }
    if (list.length < minSamples) return null;

    final lastAlert = _lastAlert[slug];
    if (lastAlert != null && now.toUtc().isBefore(lastAlert.add(cooldown))) {
      return null;
    }

    // Baseline dihitung TANPA sampel terbaru (nilai yang sedang dinilai).
    final history = list.sublist(0, list.length - 1);
    if (history.length < minSamples - 1) return null;
    final mean = _mean(history);
    final threshold = mean + zMultiplier * _stddev(history, mean);
    final floor = mean * minSpikeRatio;
    final limit = threshold > floor ? threshold : floor;
    if (tokens <= limit) return null;

    _lastAlert[slug] = now.toUtc();
    return TokenAnomaly(
      slug: slug,
      tokens: tokens,
      baselineMean: mean,
      threshold: limit,
      samples: history.length,
    );
  }

  /// Snapshot statistik saat ini untuk satu skill (tanpa menilai anomali).
  /// Dipakai host untuk introspeksi / status.
  Map<String, Object?> statsFor(String slug) {
    final list = _samples[slug] ?? const <int>[];
    if (list.isEmpty) {
      return {'slug': slug, 'samples': 0};
    }
    final mean = _mean(list);
    return {
      'slug': slug,
      'samples': list.length,
      'mean': double.parse(mean.toStringAsFixed(1)),
      'stddev': double.parse(_stddev(list, mean).toStringAsFixed(1)),
      'last': list.last,
    };
  }

  /// Daftar skill yang punya sampel (Security Center, GUI-P1-10) —
  /// tanpa nilai token, hanya slug terurut.
  List<String> get sampledSlugs => _samples.keys.toList()..sort();

  void reset([String? slug]) {
    if (slug == null) {
      _samples.clear();
      _lastAlert.clear();
    } else {
      _samples.remove(slug);
      _lastAlert.remove(slug);
    }
  }

  static double _mean(List<int> values) {
    var total = 0;
    for (final v in values) {
      total += v;
    }
    return total / values.length;
  }

  static double _stddev(List<int> values, double mean) {
    if (values.length < 2) return 0;
    var acc = 0.0;
    for (final v in values) {
      final d = v - mean;
      acc += d * d;
    }
    // Populasi (bukan sampel): cukup untuk ambang heuristik.
    return sqrt(acc / values.length);
  }
}

/// Hasil deteksi lonjakan token untuk satu skill.
class TokenAnomaly {
  const TokenAnomaly({
    required this.slug,
    required this.tokens,
    required this.baselineMean,
    required this.threshold,
    required this.samples,
  });

  final String slug;

  /// Total token giliran yang memicu alarm.
  final int tokens;

  /// Rata-rata baseline (tanpa sampel pemicu).
  final double baselineMean;

  /// Ambang efektif yang dilampaui (max dari z-threshold dan lantai rasio).
  final double threshold;

  /// Jumlah sampel baseline saat alarm.
  final int samples;

  Map<String, Object?> toJson() => {
        'slug': slug,
        'tokens': tokens,
        'baseline_mean': double.parse(baselineMean.toStringAsFixed(1)),
        'threshold': double.parse(threshold.toStringAsFixed(1)),
        'samples': samples,
      };

  @override
  String toString() =>
      'TokenAnomaly(slug: $slug, tokens: $tokens, baseline: '
      '${baselineMean.toStringAsFixed(0)}, threshold: '
      '${threshold.toStringAsFixed(0)})';
}
