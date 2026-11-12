import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';

/// Model AR hasil estimasi: rata-rata [mu], koefisien [phi] (phi[0] = lag 1),
/// dan varians galat [sigma2].
class ModelAr {
  final double mu;
  final List<double> phi;
  final double sigma2;

  const ModelAr(this.mu, this.phi, this.sigma2);
}

/// ARIMA(p, d, 0) sederhana.
///
/// Batasan: komponen MA (q) tidak ada, jadi ini sebenarnya AR dengan
/// differencing. Estimasi memakai Yule-Walker (Levinson-Durbin). Cukup untuk
/// ramalan jangka pendek dan belajar; untuk riset serius pakai paket
/// statistik khusus.
class Arima implements MetodePrediksi {
  final int p;
  final int d;
  final int horizon;

  const Arima({this.p = 2, this.d = 1, this.horizon = 5})
      : assert(p >= 0),
        assert(d >= 0 && d <= 3),
        assert(horizon > 0);

  @override
  String get nama => 'ARIMA($p,$d,0)';

  static List<double> _diff(List<double> x) =>
      [for (var i = 1; i < x.length; i++) x[i] - x[i - 1]];

  static double _autokov(List<double> x, double m, int k) {
    var s = 0.0;
    for (var t = 0; t < x.length - k; t++) {
      s += (x[t] - m) * (x[t + k] - m);
    }
    return s / x.length;
  }

  /// Estimasi AR(p) pada deret stasioner [w].
  ModelAr fitAr(List<double> w) {
    final m = MathUtils.rata(w);
    final gamma = [for (var k = 0; k <= p; k++) _autokov(w, m, k)];
    if (p == 0 || gamma[0] == 0) return ModelAr(m, const [], gamma[0]);

    var phi = List<double>.filled(p + 1, 0.0); // indeks mulai 1
    var v = gamma[0];
    for (var k = 1; k <= p; k++) {
      var acc = gamma[k];
      for (var j = 1; j < k; j++) {
        acc -= phi[j] * gamma[k - j];
      }
      final kappa = acc / v;
      final baru = List<double>.of(phi);
      baru[k] = kappa;
      for (var j = 1; j < k; j++) {
        baru[j] = phi[j] - kappa * phi[k - j];
      }
      phi = baru;
      v *= (1 - kappa * kappa);
    }
    return ModelAr(m, phi.sublist(1), v);
  }

  /// Ramalan [langkah] periode ke depan (default [horizon]) dari deret level [x].
  List<double> ramalkan(List<double> x, {int? langkah}) {
    final n = langkah ?? horizon;
    if (x.length < d + p + 5) {
      return List<double>.filled(n, x.isEmpty ? double.nan : x.last);
    }

    // seri[k] = deret setelah k kali differencing; seri[d] stasioner.
    final seri = <List<double>>[List<double>.of(x)];
    for (var k = 1; k <= d; k++) {
      seri.add(_diff(seri[k - 1]));
    }
    final model = fitAr(seri[d]);

    final hasil = <double>[];
    for (var h = 0; h < n; h++) {
      final w = seri[d];
      var f = model.mu;
      for (var i = 1; i <= p && i <= model.phi.length; i++) {
        final idx = w.length - i;
        if (idx >= 0) f += model.phi[i - 1] * (w[idx] - model.mu);
      }
      w.add(f);
      // Integrasikan kembali ke level.
      for (var k = d - 1; k >= 0; k--) {
        seri[k].add(seri[k].last + seri[k + 1].last);
      }
      hasil.add(seri[0].last);
    }
    return hasil;
  }

  @override
  Sinyal analisis(List<Candle> data) {
    final close = data.map((c) => c.close).toList();
    if (close.length < d + p + 20) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= ${d + p + 20} candle).',
      );
    }
    final f = ramalkan(close);
    final akhir = close.last;
    final ret = (f.last - akhir) / akhir;

    final acuan = close.length > 120 ? close.sublist(close.length - 120) : close;
    final sd = MathUtils.stdDev(MathUtils.returnSederhana(acuan));
    if (sd.isNaN || sd == 0) {
      return Sinyal(metode: nama, arah: Arah.tahan, skor: 0, catatan: 'Volatilitas nol.');
    }
    final z = ret / (sd * math.sqrt(horizon));
    return Sinyal.dariSkor(
      nama,
      MathUtils.tanh(z),
      catatan:
          'Ramalan $horizon periode: ${f.last.toStringAsFixed(2)} vs ${akhir.toStringAsFixed(2)} (${(ret * 100).toStringAsFixed(2)}%)',
    );
  }
}
