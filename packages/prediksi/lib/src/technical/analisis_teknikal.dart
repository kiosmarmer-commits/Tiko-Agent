import '../core/models.dart';
import 'indicators.dart';

/// Menggabungkan RSI, MACD, Bollinger, dan persilangan SMA menjadi satu
/// [Sinyal]. Tiap indikator memberi suara -1..+1, lalu dirata-rata.
class AnalisisTeknikal implements MetodePrediksi {
  final int rsiPeriode;
  final int smaCepat;
  final int smaLambat;

  const AnalisisTeknikal({
    this.rsiPeriode = 14,
    this.smaCepat = 20,
    this.smaLambat = 50,
  });

  @override
  String get nama => 'Analisis Teknikal';

  @override
  Sinyal analisis(List<Candle> data) {
    final minData = [smaLambat, 35, rsiPeriode + 1].reduce((a, b) => a > b ? a : b);
    if (data.length < minData) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (butuh >= $minData candle).',
      );
    }

    final close = data.map((c) => c.close).toList();
    final last = close.length - 1;
    final suara = <double>[];
    final alasan = <String>[];

    // RSI: oversold = bullish, overbought = bearish.
    final rsi = Indikator.rsi(close, periode: rsiPeriode)[last];
    if (rsi < 30) {
      suara.add(1);
      alasan.add('RSI ${rsi.toStringAsFixed(1)} oversold');
    } else if (rsi > 70) {
      suara.add(-1);
      alasan.add('RSI ${rsi.toStringAsFixed(1)} overbought');
    } else {
      suara.add((50 - rsi) / 100); // condong lemah ke arah mean-reversion
    }

    // MACD: histogram positif = momentum naik.
    final m = Indikator.macd(close);
    final hist = m.histogram[last];
    if (!hist.isNaN) {
      suara.add(hist > 0 ? 0.6 : -0.6);
      alasan.add('MACD histogram ${hist > 0 ? "positif" : "negatif"}');
    }

    // Bollinger: dekat pita bawah = bullish, dekat pita atas = bearish.
    final b = Indikator.bollinger(close);
    if (!b.atas[last].isNaN) {
      final lebar = b.atas[last] - b.bawah[last];
      if (lebar > 0) {
        final posisi = (close[last] - b.bawah[last]) / lebar; // 0..1
        suara.add((0.5 - posisi) * 2);
        alasan.add('posisi Bollinger ${(posisi * 100).toStringAsFixed(0)}%');
      }
    }

    // Persilangan SMA: tren jangka menengah.
    final sc = Indikator.sma(close, smaCepat)[last];
    final sl = Indikator.sma(close, smaLambat)[last];
    if (!sc.isNaN && !sl.isNaN) {
      suara.add(sc > sl ? 0.5 : -0.5);
      alasan.add('SMA$smaCepat ${sc > sl ? ">" : "<"} SMA$smaLambat');
    }

    final skor = suara.reduce((a, b) => a + b) / suara.length;
    return Sinyal.dariSkor(nama, skor, catatan: alasan.join('; '));
  }
}
