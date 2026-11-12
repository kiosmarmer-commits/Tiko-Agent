import 'dart:math' as math;

import 'dasar_ml.dart';

class _Simpul {
  final int? fitur;
  final double? ambang;
  final _Simpul? kiri;
  final _Simpul? kanan;
  final double peluang;

  const _Simpul.daun(this.peluang)
      : fitur = null,
        ambang = null,
        kiri = null,
        kanan = null;

  const _Simpul.cabang(this.fitur, this.ambang, this.kiri, this.kanan)
      : peluang = 0;

  bool get daun => fitur == null;
}

/// Pohon keputusan CART dengan kriteria Gini untuk klasifikasi biner.
class PohonKeputusan implements PengklasifikasiBiner {
  final int maksKedalaman;
  final int minSampelDaun;

  /// Jumlah fitur yang dicoba per pemecahan (null = semua). Dipakai hutan acak.
  final int? fiturPerPemecahan;
  final int benih;

  PohonKeputusan({
    this.maksKedalaman = 5,
    this.minSampelDaun = 10,
    this.fiturPerPemecahan,
    this.benih = 1,
  })  : assert(maksKedalaman > 0),
        assert(minSampelDaun > 0),
        _rnd = math.Random(benih);

  final math.Random _rnd;
  _Simpul? _akar;

  @override
  void latih(List<List<double>> x, List<int> y) =>
      latihIndeks(x, y, List<int>.generate(x.length, (i) => i));

  /// Latih memakai subset baris [indeks] (boleh berulang, untuk bootstrap).
  void latihIndeks(List<List<double>> x, List<int> y, List<int> indeks) {
    if (indeks.isEmpty) throw ArgumentError('Data latih kosong');
    _akar = _bangun(x, y, indeks, 0);
  }

  _Simpul _bangun(List<List<double>> x, List<int> y, List<int> idx, int depth) {
    final n = idx.length;
    var pos = 0;
    for (final i in idx) {
      pos += y[i];
    }
    // Smoothing Laplace supaya peluang tidak persis 0 atau 1.
    final p = (pos + 1) / (n + 2);

    if (depth >= maksKedalaman ||
        n < 2 * minSampelDaun ||
        pos == 0 ||
        pos == n) {
      return _Simpul.daun(p);
    }

    final d = x.first.length;
    final fiturCoba = List<int>.generate(d, (j) => j);
    if (fiturPerPemecahan != null && fiturPerPemecahan! < d) {
      fiturCoba.shuffle(_rnd);
      fiturCoba.removeRange(fiturPerPemecahan!, d);
    }

    final pInduk = pos / n;
    var terbaik = 2 * pInduk * (1 - pInduk) - 1e-12;
    int? fiturTerbaik;
    double ambangTerbaik = 0;

    for (final f in fiturCoba) {
      final urut = [...idx]..sort((a, b) => x[a][f].compareTo(x[b][f]));
      var kiriPos = 0;
      for (var s = 0; s < n - 1; s++) {
        kiriPos += y[urut[s]];
        final nk = s + 1, nr = n - nk;
        if (x[urut[s]][f] == x[urut[s + 1]][f]) continue;
        if (nk < minSampelDaun || nr < minSampelDaun) continue;
        final pk = kiriPos / nk;
        final pr = (pos - kiriPos) / nr;
        final gini = nk / n * 2 * pk * (1 - pk) + nr / n * 2 * pr * (1 - pr);
        if (gini < terbaik) {
          terbaik = gini;
          fiturTerbaik = f;
          ambangTerbaik = (x[urut[s]][f] + x[urut[s + 1]][f]) / 2;
        }
      }
    }

    if (fiturTerbaik == null) return _Simpul.daun(p);

    final kiri = <int>[], kanan = <int>[];
    for (final i in idx) {
      (x[i][fiturTerbaik] <= ambangTerbaik ? kiri : kanan).add(i);
    }
    return _Simpul.cabang(
      fiturTerbaik,
      ambangTerbaik,
      _bangun(x, y, kiri, depth + 1),
      _bangun(x, y, kanan, depth + 1),
    );
  }

  @override
  double peluang(List<double> x) {
    final akar = _akar;
    if (akar == null) return 0.5;
    var s = akar;
    while (!s.daun) {
      s = (x[s.fitur!] <= s.ambang! ? s.kiri : s.kanan)!;
    }
    return s.peluang;
  }
}
