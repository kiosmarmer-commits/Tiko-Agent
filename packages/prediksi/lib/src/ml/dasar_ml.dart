import 'dart:math' as math;

/// Antarmuka model klasifikasi biner (kelas 1 = harga naik).
abstract class PengklasifikasiBiner {
  /// Latih model. [y] berisi 0 atau 1.
  void latih(List<List<double>> x, List<int> y);

  /// Peluang kelas 1 (0..1) untuk satu vektor fitur.
  double peluang(List<double> x);
}

/// Penskala z-score: (nilai - rata-rata) / simpangan baku per fitur.
class Penskala {
  List<double> _rata = [];
  List<double> _sd = [];

  void fit(List<List<double>> x) {
    final d = x.first.length;
    _rata = List<double>.filled(d, 0);
    _sd = List<double>.filled(d, 1);
    for (var j = 0; j < d; j++) {
      var m = 0.0;
      for (final baris in x) {
        m += baris[j];
      }
      m /= x.length;
      var v = 0.0;
      for (final baris in x) {
        v += (baris[j] - m) * (baris[j] - m);
      }
      final sd = math.sqrt(v / x.length);
      _rata[j] = m;
      _sd[j] = sd == 0 ? 1 : sd;
    }
  }

  List<double> transform(List<double> v) =>
      [for (var j = 0; j < v.length; j++) (v[j] - _rata[j]) / _sd[j]];
}
