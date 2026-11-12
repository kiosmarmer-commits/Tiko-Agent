import 'dart:math' as math;

import '../core/models.dart';

/// Utilitas pasar prediksi: harga kontrak (0..1) dibaca sebagai probabilitas.
class PasarPrediksi {
  const PasarPrediksi();

  String get nama => 'Pasar Prediksi';

  /// Normalisasi harga beberapa hasil agar jumlahnya 1 (membuang overround).
  static List<double> normalisasi(List<double> harga) {
    final total = harga.fold<double>(0, (s, p) => s + p);
    if (total <= 0) throw ArgumentError('Jumlah harga harus positif');
    return [for (final p in harga) p / total];
  }

  /// Kelebihan jumlah probabilitas di atas 1 (margin bandar/spread).
  static double overround(List<double> harga) =>
      harga.fold<double>(0, (s, p) => s + p) - 1;

  /// Probabilitas tersirat dari odds desimal (2.0 = peluang 50%), setelah
  /// overround dibuang.
  static List<double> dariOddsDesimal(List<double> odds) =>
      normalisasi([for (final o in odds) 1 / o]);

  /// Brier score (0 = sempurna, makin kecil makin terkalibrasi baik).
  /// [hasil] berisi 1 jika peristiwa terjadi, 0 jika tidak.
  static double brierScore(List<double> prediksi, List<int> hasil) {
    if (prediksi.length != hasil.length || prediksi.isEmpty) {
      throw ArgumentError('Panjang prediksi dan hasil harus sama dan tidak kosong');
    }
    var s = 0.0;
    for (var i = 0; i < prediksi.length; i++) {
      final d = prediksi[i] - hasil[i];
      s += d * d;
    }
    return s / prediksi.length;
  }

  /// Sinyal dari probabilitas pasar bahwa harga naik. [keyakinan] 0..1 dapat
  /// diturunkan bila pasarnya sepi/tidak likuid.
  Sinyal sinyal(double probNaik, {double keyakinan = 1}) {
    final p = probNaik.clamp(0.0, 1.0).toDouble();
    final k = keyakinan.clamp(0.0, 1.0).toDouble();
    return Sinyal.dariSkor(
      nama,
      (p - 0.5) * 2 * k,
      catatan: 'Probabilitas pasar ${(p * 100).toStringAsFixed(0)}%, keyakinan ${(k * 100).toStringAsFixed(0)}%',
    );
  }
}

/// Market maker LMSR (Hanson): mekanisme penetapan harga pasar prediksi.
/// Parameter [b] mengatur likuiditas; kerugian maksimum market maker = b * ln(n).
class LmsrMarket {
  final double b;
  final List<double> _q;

  LmsrMarket({required int jumlahHasil, this.b = 100})
      : assert(jumlahHasil >= 2),
        assert(b > 0),
        _q = List<double>.filled(jumlahHasil, 0);

  /// Fungsi biaya C(q) = b * ln(sum(exp(q_i / b))), dihitung stabil.
  double _biaya(List<double> q) {
    final m = q.map((e) => e / b).reduce(math.max);
    var s = 0.0;
    for (final e in q) {
      s += math.exp(e / b - m);
    }
    return b * (m + math.log(s));
  }

  /// Harga (probabilitas) tiap hasil saat ini; jumlahnya 1.
  List<double> get harga {
    final m = _q.map((e) => e / b).reduce(math.max);
    final eksp = [for (final e in _q) math.exp(e / b - m)];
    final total = eksp.fold<double>(0, (s, e) => s + e);
    return [for (final e in eksp) e / total];
  }

  /// Beli [jumlah] saham hasil ke-[hasil]; mengembalikan biaya yang dibayar.
  /// [jumlah] negatif berarti menjual.
  double beli(int hasil, double jumlah) {
    final sebelum = _biaya(_q);
    _q[hasil] += jumlah;
    return _biaya(_q) - sebelum;
  }
}
