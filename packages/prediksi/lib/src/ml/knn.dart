import 'dasar_ml.dart';

/// K-Nearest Neighbors dengan bobot 1/(jarak + epsilon).
/// Fitur diskalakan (z-score) agar tidak ada fitur yang mendominasi jarak.
class KNN implements PengklasifikasiBiner {
  final int k;

  KNN({this.k = 15}) : assert(k > 0);

  final Penskala _skala = Penskala();
  List<List<double>> _x = [];
  List<int> _y = [];

  @override
  void latih(List<List<double>> x, List<int> y) {
    if (x.isEmpty) throw ArgumentError('Data latih kosong');
    _skala.fit(x);
    _x = x.map(_skala.transform).toList();
    _y = List<int>.of(y);
  }

  @override
  double peluang(List<double> x) {
    if (_x.isEmpty) return 0.5;
    final z = _skala.transform(x);
    final jarak = <(double, int)>[];
    for (var i = 0; i < _x.length; i++) {
      var s = 0.0;
      for (var j = 0; j < z.length; j++) {
        final d = z[j] - _x[i][j];
        s += d * d;
      }
      jarak.add((s, _y[i]));
    }
    jarak.sort((a, b) => a.$1.compareTo(b.$1));

    final n = k < jarak.length ? k : jarak.length;
    var bobotTotal = 0.0, bobotNaik = 0.0;
    for (var i = 0; i < n; i++) {
      final w = 1 / (jarak[i].$1 + 1e-9);
      bobotTotal += w;
      bobotNaik += w * jarak[i].$2;
    }
    return bobotNaik / bobotTotal;
  }
}
