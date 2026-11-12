import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';

/// Hasil regresi linear y = intercept + slope * t.
class HasilRegresi {
  final double intercept;
  final double slope;

  /// Koefisien determinasi 0..1 (seberapa lurus tren-nya).
  final double r2;

  const HasilRegresi(this.intercept, this.slope, this.r2);

  @override
  String toString() =>
      'HasilRegresi(a: $intercept, b: $slope, R2: ${r2.toStringAsFixed(3)})';
}

/// Regresi tren linear pada [jendela] harga terakhir.
///
/// Dengan [logHarga] = true regresi dilakukan pada ln(harga), sehingga slope
/// setara pertumbuhan proporsional per periode. Harga harus positif.
class RegresiTren implements MetodePrediksi {
  final int jendela;
  final bool logHarga;

  const RegresiTren({this.jendela = 60, this.logHarga = true});

  @override
  String get nama => 'Regresi Tren';

  List<double> _potong(List<double> harga) =>
      harga.length > jendela ? harga.sublist(harga.length - jendela) : harga;

  HasilRegresi fit(List<double> harga) {
    final y = logHarga ? harga.map((h) => math.log(h)).toList() : harga;
    final x = List<double>.generate(y.length, (i) => i.toDouble());
    final (a, b) = MathUtils.regresiLinear(x, y);
    final r = MathUtils.korelasi(x, y);
    return HasilRegresi(a, b, r.isNaN ? 0.0 : r * r);
  }

  /// Ramalan harga [langkah] periode setelah data terakhir.
  double ramalan(List<double> harga, int langkah) {
    final data = _potong(harga);
    final h = fit(data);
    final t = data.length - 1 + langkah;
    final y = h.intercept + h.slope * t;
    return logHarga ? math.exp(y) : y;
  }

  @override
  Sinyal analisis(List<Candle> data) {
    if (data.length < 10) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= 10 candle).',
      );
    }
    final harga = _potong(data.map((c) => c.close).toList());
    final h = fit(harga);
    final n = harga.length;

    // Perubahan proporsional yang tersirat di sepanjang jendela.
    final efek = logHarga
        ? h.slope * (n - 1)
        : h.slope * (n - 1) / MathUtils.rata(harga);

    // R2 meredam tren yang berantakan.
    final skor = MathUtils.tanh(efek * 5) * h.r2;
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'Tren ${(efek * 100).toStringAsFixed(1)}% dalam $n periode, R2 ${h.r2.toStringAsFixed(2)}',
    );
  }
}
