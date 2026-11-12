import 'dart:math' as math;

/// Utilitas statistik dasar tanpa dependensi eksternal.
class MathUtils {
  MathUtils._();

  static double rata(List<double> x) {
    if (x.isEmpty) return double.nan;
    return x.reduce((a, b) => a + b) / x.length;
  }

  /// Varians sampel (n-1).
  static double varians(List<double> x) {
    if (x.length < 2) return double.nan;
    final m = rata(x);
    var jumlah = 0.0;
    for (final v in x) {
      jumlah += (v - m) * (v - m);
    }
    return jumlah / (x.length - 1);
  }

  static double stdDev(List<double> x) => math.sqrt(varians(x));

  /// Return sederhana antar elemen berurutan: (x[i] - x[i-1]) / x[i-1].
  static List<double> returnSederhana(List<double> harga) {
    final hasil = <double>[];
    for (var i = 1; i < harga.length; i++) {
      hasil.add((harga[i] - harga[i - 1]) / harga[i - 1]);
    }
    return hasil;
  }

  /// Return logaritmik: ln(x[i] / x[i-1]).
  static List<double> returnLog(List<double> harga) {
    final hasil = <double>[];
    for (var i = 1; i < harga.length; i++) {
      hasil.add(math.log(harga[i] / harga[i - 1]));
    }
    return hasil;
  }

  /// Korelasi Pearson dua deret sama panjang.
  static double korelasi(List<double> a, List<double> b) {
    if (a.length != b.length || a.length < 2) return double.nan;
    final ma = rata(a), mb = rata(b);
    var sab = 0.0, saa = 0.0, sbb = 0.0;
    for (var i = 0; i < a.length; i++) {
      sab += (a[i] - ma) * (b[i] - mb);
      saa += (a[i] - ma) * (a[i] - ma);
      sbb += (b[i] - mb) * (b[i] - mb);
    }
    return sab / math.sqrt(saa * sbb);
  }

  /// Persentil (0..100) dengan interpolasi linear.
  static double persentil(List<double> x, double p) {
    if (x.isEmpty) return double.nan;
    final s = [...x]..sort();
    final pos = (p / 100) * (s.length - 1);
    final bawah = pos.floor();
    final atas = pos.ceil();
    if (bawah == atas) return s[bawah];
    return s[bawah] + (s[atas] - s[bawah]) * (pos - bawah);
  }

  /// Regresi linear sederhana y = a + b*x. Mengembalikan (a, b).
  static (double, double) regresiLinear(List<double> x, List<double> y) {
    final mx = rata(x), my = rata(y);
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < x.length; i++) {
      sxy += (x[i] - mx) * (y[i] - my);
      sxx += (x[i] - mx) * (x[i] - mx);
    }
    final b = sxy / sxx;
    return (my - b * mx, b);
  }

  /// Tangen hiperbolik, dipakai untuk menekan nilai ke rentang -1..1.
  static double tanh(double x) {
    if (x.isNaN) return 0;
    final v = x.clamp(-20.0, 20.0).toDouble();
    final e = math.exp(2 * v);
    return (e - 1) / (e + 1);
  }
}
