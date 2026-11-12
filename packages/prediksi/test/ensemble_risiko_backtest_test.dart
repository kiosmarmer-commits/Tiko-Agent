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

/// Metode palsu dengan skor tetap, untuk menguji penggabung dan backtest.
class _Tetap implements MetodePrediksi {
  final double skor;
  const _Tetap(this.skor);

  @override
  String get nama => 'Tetap($skor)';

  @override
  Sinyal analisis(List<Candle> data) => Sinyal.dariSkor(nama, skor);
}

void main() {
  group('Ensemble', () {
    test('gabungkanSinyal: rata-rata sederhana dan kesepakatan', () {
      final h = Ensemble.gabungkanSinyal([
        Sinyal.dariSkor('a', 0.8),
        Sinyal.dariSkor('b', -0.2),
      ]);
      expect(h.sinyal.skor, closeTo(0.3, 1e-9));
      expect(h.sinyal.arah, Arah.beli);
      expect(h.kesepakatan, closeTo(0.5, 1e-9)); // b = tahan, a = beli
    });

    test('gabungkanSinyal: bobot mengubah hasil', () {
      final h = Ensemble.gabungkanSinyal(
        [Sinyal.dariSkor('a', 0.8), Sinyal.dariSkor('b', -0.2)],
        bobot: [3, 1],
      );
      expect(h.sinyal.skor, closeTo(0.55, 1e-9));
    });

    test('gabungkanSinyal: kosong -> tahan', () {
      expect(Ensemble.gabungkanSinyal([]).sinyal.arah, Arah.tahan);
    });

    test('bobot tidak sepanjang sinyal -> error', () {
      expect(
        () => Ensemble.gabungkanSinyal([Sinyal.dariSkor('a', 0.5)], bobot: [1, 2]),
        throwsArgumentError,
      );
    });

    test('hitung: metode candle + sinyal tambahan', () {
      final e = Ensemble(const [_Tetap(0.8), _Tetap(0.6)]);
      final data = candles([1, 2, 3]);
      expect(e.analisis(data).arah, Arah.beli);
      expect(e.hitung(data).kesepakatan, closeTo(1, 1e-9));

      final h = e.hitung(data, tambahan: [Sinyal.dariSkor('x', -0.9)]);
      expect(h.sinyal.skor, closeTo((0.8 + 0.6 - 0.9) / 3, 1e-9));
      expect(h.sinyal.arah, Arah.tahan);
    });
  });

  group('ManajemenRisiko', () {
    test('ukuranPosisi: risiko 1% dengan stop 5', () {
      final u = ManajemenRisiko.ukuranPosisi(
        modal: 10000,
        risikoPersen: 1,
        hargaMasuk: 100,
        hargaStop: 95,
      );
      expect(u, closeTo(20, 1e-9));
    });

    test('ukuranPosisi: dibatasi tanpa leverage', () {
      final u = ManajemenRisiko.ukuranPosisi(
        modal: 10000,
        risikoPersen: 1,
        hargaMasuk: 100,
        hargaStop: 99.9,
      );
      expect(u, closeTo(100, 1e-9)); // maksimal modal / harga
    });

    test('stop sama dengan harga masuk -> error', () {
      expect(
        () => ManajemenRisiko.ukuranPosisi(
          modal: 100,
          risikoPersen: 1,
          hargaMasuk: 10,
          hargaStop: 10,
        ),
        throwsArgumentError,
      );
    });

    test('stop ATR dan rasio risiko-imbalan', () {
      expect(ManajemenRisiko.stopLossAtr(hargaMasuk: 100, atr: 2), 96);
      expect(
        ManajemenRisiko.stopLossAtr(hargaMasuk: 100, atr: 2, posisiLong: false),
        104,
      );
      expect(
        ManajemenRisiko.rasioRisikoImbalan(
          hargaMasuk: 100,
          hargaStop: 95,
          hargaTarget: 110,
        ),
        closeTo(2, 1e-9),
      );
    });

    test('Kelly', () {
      expect(
        ManajemenRisiko.kelly(peluangMenang: 0.6, rasioMenangKalah: 1),
        closeTo(0.2, 1e-9),
      );
      expect(
        ManajemenRisiko.kelly(peluangMenang: 0.4, rasioMenangKalah: 1),
        0,
      );
      expect(
        ManajemenRisiko.kellyFraksi(peluangMenang: 0.6, rasioMenangKalah: 1),
        closeTo(0.1, 1e-9),
      );
    });

    test('VaR dan expected shortfall', () {
      final r = [for (var i = 0; i < 100; i++) (i - 50) / 1000];
      final v = ManajemenRisiko.valueAtRisk(r);
      expect(v, closeTo(0.04505, 1e-9));
      expect(ManajemenRisiko.expectedShortfall(r), greaterThanOrEqualTo(v));
    });

    test('maxDrawdown', () {
      expect(ManajemenRisiko.maxDrawdown([100, 120, 90, 110]), closeTo(0.25, 1e-9));
      expect(ManajemenRisiko.maxDrawdown([100, 110, 120]), 0);
    });

    test('Sharpe', () {
      expect(
        ManajemenRisiko.sharpe([0.01, 0.03], periodePerTahun: 1),
        closeTo(math.sqrt(2), 1e-9),
      );
      expect(ManajemenRisiko.sharpe([0.01, 0.01, 0.01]), 0); // tanpa variasi
    });
  });

  group('Backtest', () {
    final naik = candles([for (var i = 0; i < 200; i++) 100 * math.exp(0.005 * i)]);

    test('selalu beli tanpa biaya = beli dan tahan', () {
      const bt = Backtest(mulai: 50, biayaPerTransaksi: 0);
      final h = bt.jalankan(const _Tetap(0.9), naik);
      expect(h.totalReturn, closeTo(h.returnBeliTahan, 1e-9));
      expect(h.transaksi.length, 1);
      expect(h.winRate, 1);
      expect(h.ekuitas.length, naik.length - 50);
      expect(h.jumlahPerubahanPosisi, 1);
    });

    test('biaya transaksi menurunkan hasil', () {
      final tanpa = const Backtest(mulai: 50, biayaPerTransaksi: 0)
          .jalankan(const _Tetap(0.9), naik);
      final dengan = const Backtest(mulai: 50, biayaPerTransaksi: 0.01)
          .jalankan(const _Tetap(0.9), naik);
      expect(dengan.totalReturn, lessThan(tanpa.totalReturn));
    });

    test('selalu jual tanpa short -> tunai, tidak ada transaksi', () {
      final h = const Backtest(mulai: 50).jalankan(const _Tetap(-0.9), naik);
      expect(h.transaksi, isEmpty);
      expect(h.totalReturn, closeTo(0, 1e-12));
    });

    test('selalu jual dengan short pada tren naik -> rugi', () {
      final h = const Backtest(mulai: 50, izinkanShort: true, biayaPerTransaksi: 0)
          .jalankan(const _Tetap(-0.9), naik);
      expect(h.totalReturn, lessThan(0));
      expect(h.winRate, 0);
    });

    test('interval besar tetap mempertahankan posisi', () {
      final h = const Backtest(mulai: 50, interval: 20, biayaPerTransaksi: 0)
          .jalankan(const _Tetap(0.9), naik);
      expect(h.totalReturn, closeTo(h.returnBeliTahan, 1e-9));
    });

    test('data terlalu sedikit -> error', () {
      expect(
        () => const Backtest(mulai: 100).jalankan(const _Tetap(0.9), candles([1, 2, 3])),
        throwsArgumentError,
      );
    });
  });
}
