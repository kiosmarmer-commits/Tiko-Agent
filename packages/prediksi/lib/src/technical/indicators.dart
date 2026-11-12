import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';

/// Indikator analisis teknikal. Semua fungsi menerima deret harga penutupan
/// (atau candle) dan mengembalikan deret sepanjang input; nilai yang belum
/// bisa dihitung diisi `double.nan`.
class Indikator {
  Indikator._();

  /// Simple Moving Average.
  static List<double> sma(List<double> x, int periode) {
    final out = List<double>.filled(x.length, double.nan);
    if (periode <= 0 || x.length < periode) return out;
    var jumlah = 0.0;
    for (var i = 0; i < x.length; i++) {
      jumlah += x[i];
      if (i >= periode) jumlah -= x[i - periode];
      if (i >= periode - 1) out[i] = jumlah / periode;
    }
    return out;
  }

  /// Exponential Moving Average (seed = SMA periode pertama).
  static List<double> ema(List<double> x, int periode) {
    final out = List<double>.filled(x.length, double.nan);
    if (periode <= 0 || x.length < periode) return out;
    final k = 2 / (periode + 1);
    var prev = MathUtils.rata(x.sublist(0, periode));
    out[periode - 1] = prev;
    for (var i = periode; i < x.length; i++) {
      prev = x[i] * k + prev * (1 - k);
      out[i] = prev;
    }
    return out;
  }

  /// Relative Strength Index (smoothing Wilder).
  static List<double> rsi(List<double> x, {int periode = 14}) {
    final out = List<double>.filled(x.length, double.nan);
    if (x.length <= periode) return out;
    var gain = 0.0, loss = 0.0;
    for (var i = 1; i <= periode; i++) {
      final d = x[i] - x[i - 1];
      if (d >= 0) {
        gain += d;
      } else {
        loss -= d;
      }
    }
    var avgGain = gain / periode;
    var avgLoss = loss / periode;
    out[periode] = _rsi(avgGain, avgLoss);
    for (var i = periode + 1; i < x.length; i++) {
      final d = x[i] - x[i - 1];
      final g = d > 0 ? d : 0.0;
      final l = d < 0 ? -d : 0.0;
      avgGain = (avgGain * (periode - 1) + g) / periode;
      avgLoss = (avgLoss * (periode - 1) + l) / periode;
      out[i] = _rsi(avgGain, avgLoss);
    }
    return out;
  }

  static double _rsi(double avgGain, double avgLoss) {
    if (avgLoss == 0) return 100;
    final rs = avgGain / avgLoss;
    return 100 - 100 / (1 + rs);
  }

  /// MACD: garis MACD, sinyal, dan histogram.
  static ({List<double> macd, List<double> sinyal, List<double> histogram})
      macd(List<double> x, {int cepat = 12, int lambat = 26, int sinyal = 9}) {
    final emaCepat = ema(x, cepat);
    final emaLambat = ema(x, lambat);
    final garis = List<double>.generate(
      x.length,
      (i) => emaCepat[i] - emaLambat[i],
    );
    // EMA sinyal hanya dihitung dari bagian garis MACD yang valid.
    final awal = lambat - 1;
    final valid = garis.sublist(awal);
    final emaSinyal = ema(valid, sinyal);
    final garisSinyal = List<double>.filled(x.length, double.nan);
    for (var i = 0; i < valid.length; i++) {
      garisSinyal[awal + i] = emaSinyal[i];
    }
    final hist = List<double>.generate(
      x.length,
      (i) => garis[i] - garisSinyal[i],
    );
    return (macd: garis, sinyal: garisSinyal, histogram: hist);
  }

  /// Bollinger Bands.
  static ({List<double> tengah, List<double> atas, List<double> bawah})
      bollinger(List<double> x, {int periode = 20, double k = 2}) {
    final tengah = sma(x, periode);
    final atas = List<double>.filled(x.length, double.nan);
    final bawah = List<double>.filled(x.length, double.nan);
    for (var i = periode - 1; i < x.length; i++) {
      final sd = MathUtils.stdDev(x.sublist(i - periode + 1, i + 1));
      atas[i] = tengah[i] + k * sd;
      bawah[i] = tengah[i] - k * sd;
    }
    return (tengah: tengah, atas: atas, bawah: bawah);
  }

  /// Average True Range (volatilitas).
  static List<double> atr(List<Candle> c, {int periode = 14}) {
    final out = List<double>.filled(c.length, double.nan);
    if (c.length <= periode) return out;
    final tr = <double>[];
    for (var i = 1; i < c.length; i++) {
      final hl = c[i].high - c[i].low;
      final hc = (c[i].high - c[i - 1].close).abs();
      final lc = (c[i].low - c[i - 1].close).abs();
      tr.add(math.max(hl, math.max(hc, lc)));
    }
    var prev = MathUtils.rata(tr.sublist(0, periode));
    out[periode] = prev;
    for (var i = periode; i < tr.length; i++) {
      prev = (prev * (periode - 1) + tr[i]) / periode;
      out[i + 1] = prev;
    }
    return out;
  }

  /// Level support & resistance dari swing high/low lokal.
  /// [jendela] = jumlah candle di kiri/kanan untuk mengonfirmasi swing.
  static ({List<double> support, List<double> resistance}) supportResistance(
    List<Candle> c, {
    int jendela = 5,
  }) {
    final sup = <double>[];
    final res = <double>[];
    for (var i = jendela; i < c.length - jendela; i++) {
      var swingHigh = true, swingLow = true;
      for (var j = 1; j <= jendela; j++) {
        if (c[i].high < c[i - j].high || c[i].high < c[i + j].high) {
          swingHigh = false;
        }
        if (c[i].low > c[i - j].low || c[i].low > c[i + j].low) {
          swingLow = false;
        }
      }
      if (swingHigh) res.add(c[i].high);
      if (swingLow) sup.add(c[i].low);
    }
    return (support: sup, resistance: res);
  }

  /// Level retracement Fibonacci antara [rendah] dan [tinggi].
  static Map<String, double> fibonacci(double rendah, double tinggi) {
    final selisih = tinggi - rendah;
    const rasio = {
      '0%': 0.0,
      '23.6%': 0.236,
      '38.2%': 0.382,
      '50%': 0.5,
      '61.8%': 0.618,
      '78.6%': 0.786,
      '100%': 1.0,
    };
    return {for (final e in rasio.entries) e.key: tinggi - selisih * e.value};
  }
}
