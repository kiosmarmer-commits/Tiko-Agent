import 'dart:math' as math;

import 'dasar_ml.dart';
import 'pohon_keputusan.dart';

/// Random forest: rata-rata peluang dari banyak pohon yang dilatih pada
/// sampel bootstrap dan subset fitur acak di tiap pemecahan.
class HutanAcak implements PengklasifikasiBiner {
  final int jumlahPohon;
  final int maksKedalaman;
  final int minSampelDaun;
  final int benih;

  HutanAcak({
    this.jumlahPohon = 50,
    this.maksKedalaman = 5,
    this.minSampelDaun = 10,
    this.benih = 7,
  }) : assert(jumlahPohon > 0);

  final List<PohonKeputusan> _pohon = [];

  @override
  void latih(List<List<double>> x, List<int> y) {
    if (x.isEmpty) throw ArgumentError('Data latih kosong');
    _pohon.clear();
    final rnd = math.Random(benih);
    final d = x.first.length;
    final fiturPerPemecahan = math.max(1, math.sqrt(d).round());

    for (var t = 0; t < jumlahPohon; t++) {
      final idx = List<int>.generate(x.length, (_) => rnd.nextInt(x.length));
      final pohon = PohonKeputusan(
        maksKedalaman: maksKedalaman,
        minSampelDaun: minSampelDaun,
        fiturPerPemecahan: fiturPerPemecahan,
        benih: benih + t + 1,
      )..latihIndeks(x, y, idx);
      _pohon.add(pohon);
    }
  }

  @override
  double peluang(List<double> x) {
    if (_pohon.isEmpty) return 0.5;
    var jumlah = 0.0;
    for (final p in _pohon) {
      jumlah += p.peluang(x);
    }
    return jumlah / _pohon.length;
  }
}
