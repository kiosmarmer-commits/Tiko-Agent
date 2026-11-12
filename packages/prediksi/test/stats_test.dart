import 'dart:math' as math;

import 'package:prediksi/prediksi.dart';
import 'package:test/test.dart';

List<Candle> candles(List<double> closes) => [
      for (var i = 0; i < closes.length; i++)
        Candle(
          waktu: DateTime.utc(2020, 1, 1).add(Duration(days: i)),
          open: closes[i],
          high: closes[i],
          low: closes[i],
          close: closes[i],
        ),
    ];

void main() {
  test('MathUtils.tanh', () {
    expect(MathUtils.tanh(0), closeTo(0, 1e-12));
    expect(MathUtils.tanh(100), closeTo(1, 1e-9));
    expect(MathUtils.tanh(-100), closeTo(-1, 1e-9));
  });

  group('RegresiTren', () {
    final naik = [for (var i = 0; i < 80; i++) 100 * math.exp(0.01 * i)];
    final turun = [for (var i = 0; i < 80; i++) 100 * math.exp(-0.01 * i)];

    test('tren naik mulus -> beli', () {
      final s = const RegresiTren().analisis(candles(naik));
      expect(s.arah, Arah.beli);
      expect(s.skor, greaterThan(0.9));
    });

    test('tren turun mulus -> jual', () {
      expect(const RegresiTren().analisis(candles(turun)).arah, Arah.jual);
    });

    test('ramalan mengikuti garis tren', () {
      final f = const RegresiTren(jendela: 80).ramalan(naik, 5);
      expect(f, closeTo(100 * math.exp(0.01 * 84), 1e-6));
    });
  });

  group('Arima', () {
    test('tren linear: ramalan melanjutkan kenaikan konstan', () {
      final x = [for (var i = 0; i < 40; i++) 100.0 + 2 * i];
      final f = const Arima(p: 1, d: 1, horizon: 3).ramalkan(x);
      expect(f.length, 3);
      expect(f.last, closeTo(x.last + 6, 1e-9));
    });

    test('deret konstan tanpa differencing -> ramalan konstan', () {
      final x = List<double>.filled(40, 50);
      final f = const Arima(p: 2, d: 0, horizon: 2).ramalkan(x);
      expect(f, everyElement(closeTo(50, 1e-9)));
    });

    test('data kurang -> tahan', () {
      final s = const Arima().analisis(candles([1, 2, 3]));
      expect(s.arah, Arah.tahan);
    });
  });

  group('MonteCarlo', () {
    final harga = [
      for (var i = 0; i < 60; i++) 100 * math.exp(0.01 * i + 0.005 * math.sin(i)),
    ];

    test('hasil bisa diulang dengan benih sama', () {
      const mc = MonteCarlo(jumlahJalur: 500, horizon: 10);
      expect(mc.simulasi(harga).median, mc.simulasi(harga).median);
    });

    test('jumlah jalur dan urutan persentil', () {
      const mc = MonteCarlo(jumlahJalur: 500, horizon: 10);
      final h = mc.simulasi(harga);
      expect(h.hargaAkhir.length, 500);
      expect(h.persentilHarga(5), lessThanOrEqualTo(h.persentilHarga(95)));
    });

    test('tren naik kuat -> P(naik) tinggi -> beli (gbm dan bootstrap)', () {
      for (final mode in ModeSimulasi.values) {
        final s = MonteCarlo(jumlahJalur: 500, horizon: 10, mode: mode)
            .analisis(candles(harga));
        expect(s.arah, Arah.beli, reason: mode.name);
      }
    });
  });
}
