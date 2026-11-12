import '../core/math_utils.dart';
import '../core/models.dart';
import '../technical/indicators.dart';

/// Membangun fitur dan label untuk model ML dari deret candle.
///
/// Fitur per titik waktu i (hanya memakai data sampai i, tanpa melihat masa
/// depan): return 1/5/10 periode, volatilitas 10 periode, RSI14, dan jarak
/// harga ke SMA20 dan SMA50.
class FiturPasar {
  static const namaFitur = [
    'ret1',
    'ret5',
    'ret10',
    'vol10',
    'rsi14',
    'jarakSma20',
    'jarakSma50',
  ];

  /// Indeks paling awal yang punya semua fitur.
  static const minIndeks = 50;

  final List<double> _close;
  final List<double> _rsi;
  final List<double> _sma20;
  final List<double> _sma50;

  FiturPasar._(this._close, this._rsi, this._sma20, this._sma50);

  factory FiturPasar(List<Candle> candle) {
    final close = candle.map((c) => c.close).toList();
    return FiturPasar._(
      close,
      Indikator.rsi(close),
      Indikator.sma(close, 20),
      Indikator.sma(close, 50),
    );
  }

  int get panjang => _close.length;

  /// Vektor fitur di indeks [i], atau null jika belum cukup data.
  List<double>? vektor(int i) {
    if (i < minIndeks || i >= _close.length) return null;
    final ret = <double>[
      for (var j = i - 9; j <= i; j++) _close[j] / _close[j - 1] - 1,
    ];
    final v = <double>[
      _close[i] / _close[i - 1] - 1,
      _close[i] / _close[i - 5] - 1,
      _close[i] / _close[i - 10] - 1,
      MathUtils.stdDev(ret),
      _rsi[i] / 100,
      _close[i] / _sma20[i] - 1,
      _close[i] / _sma50[i] - 1,
    ];
    return v.any((e) => e.isNaN || e.isInfinite) ? null : v;
  }

  /// Data latih: fitur di i, label 1 jika harga i+[horizon] > harga i.
  /// Indeks terakhir yang dipakai adalah panjang-1-horizon, jadi tidak ada
  /// kebocoran informasi masa depan untuk prediksi di titik terakhir.
  ({List<List<double>> x, List<int> y}) dataLatih({int horizon = 5}) {
    final x = <List<double>>[];
    final y = <int>[];
    for (var i = minIndeks; i < _close.length - horizon; i++) {
      final v = vektor(i);
      if (v == null) continue;
      x.add(v);
      y.add(_close[i + horizon] > _close[i] ? 1 : 0);
    }
    return (x: x, y: y);
  }
}
