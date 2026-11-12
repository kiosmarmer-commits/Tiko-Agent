import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';
import '../technical/indicators.dart';

/// Indeks volatilitas VIX sebagai ukuran ketakutan pasar.
///
/// Mode kontrarian (default): ketakutan ekstrem cenderung dekat dasar pasar
/// (bullish), sedangkan kepuasan ekstrem (VIX sangat rendah) mendahului
/// koreksi. Set [kontrarian] = false bila ingin membaca VIX tinggi sebagai
/// bearish (mengikuti tren).
class IndeksVix {
  final bool kontrarian;

  const IndeksVix({this.kontrarian = true});

  String get nama => 'VIX';

  Sinyal sinyal(double vix) {
    final double dasar;
    final String ket;
    if (vix > 40) {
      dasar = 0.7;
      ket = 'panik';
    } else if (vix > 30) {
      dasar = 0.5;
      ket = 'ketakutan tinggi';
    } else if (vix > 20) {
      dasar = 0.1;
      ket = 'waspada';
    } else if (vix > 15) {
      dasar = 0.0;
      ket = 'normal';
    } else {
      dasar = -0.3;
      ket = 'sangat tenang (rawan puas diri)';
    }
    return Sinyal.dariSkor(
      nama,
      kontrarian ? dasar : -dasar,
      catatan: 'VIX ${vix.toStringAsFixed(1)}: $ket',
    );
  }
}

/// Indeks Fear & Greed skala 0-100 (0 = takut ekstrem, 100 = serakah ekstrem).
/// Dibaca secara kontrarian: takut = peluang beli, serakah = hati-hati.
class FearGreed {
  const FearGreed();

  String get nama => 'Fear & Greed';

  Sinyal sinyal(double indeks, {bool kontrarian = true}) {
    final double dasar;
    final String ket;
    if (indeks <= 25) {
      dasar = 0.6;
      ket = 'takut ekstrem';
    } else if (indeks <= 45) {
      dasar = 0.25;
      ket = 'takut';
    } else if (indeks <= 55) {
      dasar = 0.0;
      ket = 'netral';
    } else if (indeks <= 75) {
      dasar = -0.25;
      ket = 'serakah';
    } else {
      dasar = -0.6;
      ket = 'serakah ekstrem';
    }
    return Sinyal.dariSkor(
      nama,
      kontrarian ? dasar : -dasar,
      catatan: 'Indeks ${indeks.toStringAsFixed(0)}: $ket',
    );
  }
}

/// Indeks Fear & Greed versi lokal yang dihitung dari candle (tanpa data luar).
///
/// Rata-rata empat komponen berskala 0-100: momentum terhadap SMA125, RSI14,
/// volatilitas 14 hari relatif 100 hari (volatilitas tinggi = takut), dan
/// jarak dari puncak 250 hari. Ini bukan indeks CNN, hanya pendekatan sederhana.
class IndeksTakutSerakahLokal implements MetodePrediksi {
  const IndeksTakutSerakahLokal();

  @override
  String get nama => 'Fear & Greed Lokal';

  static double _skala(double x) => x.clamp(0.0, 1.0).toDouble() * 100;

  /// Nilai indeks 0-100, atau null jika data < 130 candle.
  double? indeks(List<Candle> data) {
    if (data.length < 130) return null;
    final close = data.map((c) => c.close).toList();
    final n = close.length;
    final last = n - 1;

    // Momentum: -10% di bawah SMA125 = 0, +10% di atasnya = 100.
    final sma125 = Indikator.sma(close, 125)[last];
    final sMomentum = _skala((close[last] / sma125 - 1 + 0.1) / 0.2);

    final sRsi = Indikator.rsi(close)[last];

    // Volatilitas: rasio 0.5 = 100 (tenang), rasio 2.0 = 0 (gejolak).
    final ret = MathUtils.returnSederhana(close);
    final v14 = MathUtils.stdDev(ret.sublist(ret.length - 14));
    final panjangAcuan = math.min(100, ret.length);
    final v100 = MathUtils.stdDev(ret.sublist(ret.length - panjangAcuan));
    final rasio = v100 == 0 ? 1.0 : v14 / v100;
    final sVol = _skala(1 - (rasio - 0.5) / 1.5);

    // Jarak dari puncak 250 hari: 0% = 100, -20% atau lebih = 0.
    final jendela = close.sublist(math.max(0, n - 250));
    final tinggi = jendela.reduce(math.max);
    final sPuncak = _skala(1 + (close[last] / tinggi - 1) / 0.2);

    return (sMomentum + sRsi + sVol + sPuncak) / 4;
  }

  @override
  Sinyal analisis(List<Candle> data) {
    final idx = indeks(data);
    if (idx == null) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= 130 candle).',
      );
    }
    final s = const FearGreed().sinyal(idx);
    return Sinyal(
      metode: nama,
      arah: s.arah,
      skor: s.skor,
      catatan: 'Indeks lokal ${idx.toStringAsFixed(0)}/100: ${s.catatan}',
    );
  }
}
