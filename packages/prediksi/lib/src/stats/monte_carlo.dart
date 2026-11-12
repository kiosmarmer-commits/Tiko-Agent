import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';

/// Cara membangkitkan return acak.
enum ModeSimulasi {
  /// Geometric Brownian Motion: return log ~ Normal(rata-rata, std) historis.
  gbm,

  /// Bootstrap: mengambil ulang return historis secara acak (tanpa asumsi normal).
  bootstrap,
}

/// Distribusi harga akhir hasil simulasi.
class HasilMonteCarlo {
  final double hargaAwal;

  /// Harga akhir tiap jalur, terurut menaik.
  final List<double> hargaAkhir;

  HasilMonteCarlo(this.hargaAwal, List<double> harga)
      : hargaAkhir = ([...harga]..sort());

  double persentilHarga(double p) => MathUtils.persentil(hargaAkhir, p);

  double get median => persentilHarga(50);

  double get rataRata => MathUtils.rata(hargaAkhir);

  /// Peluang harga akhir di atas harga awal (0..1).
  double get probNaik =>
      hargaAkhir.where((h) => h > hargaAwal).length / hargaAkhir.length;

  /// Value at Risk 95%: kerugian proporsional pada persentil ke-5 (>= 0).
  double get var95 =>
      math.max(0.0, (hargaAwal - persentilHarga(5)) / hargaAwal);
}

/// Simulasi Monte Carlo atas harga penutupan.
///
/// Hasilnya bergantung pada rata-rata dan volatilitas historis; keduanya
/// tidak stabil, jadi anggap ini peta kemungkinan, bukan ramalan.
class MonteCarlo implements MetodePrediksi {
  final int jumlahJalur;
  final int horizon;
  final ModeSimulasi mode;

  /// Benih acak agar hasil bisa diulang.
  final int benih;

  const MonteCarlo({
    this.jumlahJalur = 5000,
    this.horizon = 21,
    this.mode = ModeSimulasi.gbm,
    this.benih = 42,
  })  : assert(jumlahJalur > 0),
        assert(horizon > 0);

  @override
  String get nama => 'Monte Carlo (${mode.name})';

  static double _normal(math.Random rnd) {
    final u1 = 1 - rnd.nextDouble(); // hindari 0
    final u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// Jalankan simulasi dari deret [harga] (harus positif, minimal 3 titik).
  HasilMonteCarlo simulasi(List<double> harga) {
    final rl = MathUtils.returnLog(harga);
    final mu = MathUtils.rata(rl);
    final sigma = MathUtils.stdDev(rl);
    final rnd = math.Random(benih);
    final awal = harga.last;

    final akhir = <double>[];
    for (var i = 0; i < jumlahJalur; i++) {
      var logH = 0.0;
      for (var t = 0; t < horizon; t++) {
        logH += switch (mode) {
          ModeSimulasi.gbm => mu + sigma * _normal(rnd),
          ModeSimulasi.bootstrap => rl[rnd.nextInt(rl.length)],
        };
      }
      akhir.add(awal * math.exp(logH));
    }
    return HasilMonteCarlo(awal, akhir);
  }

  @override
  Sinyal analisis(List<Candle> data) {
    if (data.length < 30) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= 30 candle).',
      );
    }
    final hasil = simulasi(data.map((c) => c.close).toList());
    final skor = (hasil.probNaik - 0.5) * 2;
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'P(naik) ${(hasil.probNaik * 100).toStringAsFixed(0)}%, median ${hasil.median.toStringAsFixed(2)}, '
          'VaR95 ${(hasil.var95 * 100).toStringAsFixed(1)}% ($horizon periode)',
    );
  }
}
