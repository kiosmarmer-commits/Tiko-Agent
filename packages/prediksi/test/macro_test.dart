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
  group('YieldCurve', () {
    const yc = YieldCurve();

    test('inversi dalam -> jual', () {
      final s = yc.sinyal(hasilPanjang: 4.0, hasilPendek: 4.5);
      expect(s.skor, closeTo(-0.9, 1e-9));
      expect(s.arah, Arah.jual);
    });

    test('kurva normal -> beli', () {
      expect(yc.sinyal(hasilPanjang: 4.5, hasilPendek: 4.0).arah, Arah.beli);
    });

    test('menanjak lagi setelah inversi -> jual', () {
      final s = yc.sinyal(
        hasilPanjang: 4.1,
        hasilPendek: 4.0,
        spreadSebelumnya: -0.2,
      );
      expect(s.arah, Arah.jual);
    });
  });

  group('SukuBungaInflasi', () {
    const m = SukuBungaInflasi();

    test('suku bunga naik dan inflasi tinggi -> jual', () {
      final s = m.sinyal(sukuBunga: 6.0, sukuBungaSebelumnya: 4.5, inflasi: 5.0);
      expect(s.arah, Arah.jual);
    });

    test('suku bunga turun dan inflasi terkendali -> beli', () {
      final s = m.sinyal(sukuBunga: 4.0, sukuBungaSebelumnya: 5.5, inflasi: 2.0);
      expect(s.arah, Arah.beli);
    });
  });

  group('PmiManufaktur', () {
    const p = PmiManufaktur();

    test('PMI 56 -> beli, PMI 44 -> jual', () {
      expect(p.sinyal(pmi: 56).arah, Arah.beli);
      expect(p.sinyal(pmi: 44).arah, Arah.jual);
    });
  });

  group('AturanSahm', () {
    const s = AturanSahm();

    test('lonjakan pengangguran >= 0,5 poin -> jual', () {
      final data = [...List<double>.filled(12, 4.0), 4.6, 4.6, 4.6];
      final r = s.sinyal(data);
      expect(r.skor, closeTo(-0.9, 1e-9));
      expect(r.arah, Arah.jual);
    });

    test('pengangguran stabil -> tahan', () {
      expect(s.sinyal(List<double>.filled(15, 4.0)).arah, Arah.tahan);
    });

    test('data kurang -> tahan', () {
      expect(s.sinyal([4.0, 4.1]).arah, Arah.tahan);
    });
  });

  group('Sentimen', () {
    test('VIX tinggi: kontrarian beli, non-kontrarian jual', () {
      expect(const IndeksVix().sinyal(35).arah, Arah.beli);
      expect(const IndeksVix(kontrarian: false).sinyal(35).arah, Arah.jual);
    });

    test('Fear & Greed', () {
      const fg = FearGreed();
      expect(fg.sinyal(10).arah, Arah.beli);
      expect(fg.sinyal(90).arah, Arah.jual);
      expect(fg.sinyal(50).arah, Arah.tahan);
    });

    test('indeks lokal: tren naik -> serakah, tren turun -> takut', () {
      final naik = [
        for (var i = 0; i < 200; i++)
          100 * math.exp(0.01 * i + 0.003 * math.sin(i * 1.7)),
      ];
      final turun = [
        for (var i = 0; i < 200; i++)
          100 * math.exp(-0.01 * i + 0.003 * math.sin(i * 1.7)),
      ];
      const lokal = IndeksTakutSerakahLokal();
      expect(lokal.indeks(candles(naik))!, greaterThan(75));
      expect(lokal.indeks(candles(turun))!, lessThan(25));
      expect(lokal.analisis(candles(naik)).arah, Arah.jual);
      expect(lokal.analisis(candles(turun)).arah, Arah.beli);
    });

    test('indeks lokal: data kurang -> null dan tahan', () {
      final sedikit = candles(List<double>.filled(50, 100));
      expect(const IndeksTakutSerakahLokal().indeks(sedikit), isNull);
      expect(const IndeksTakutSerakahLokal().analisis(sedikit).arah, Arah.tahan);
    });
  });

  group('PapanMakro', () {
    const papan = PapanMakro();

    test('tanpa data -> tahan', () {
      expect(papan.gabungan(const DataMakro()).arah, Arah.tahan);
    });

    test('hanya VIX -> sama dengan sinyal VIX', () {
      final g = papan.gabungan(const DataMakro(vix: 35));
      expect(g.skor, closeTo(0.5, 1e-9));
    });

    test('indikator yang datanya tidak lengkap dilewati', () {
      final daftar = papan.semua(const DataMakro(hasilPanjang: 4.0, pmi: 52));
      expect(daftar.length, 1); // yield curve butuh hasilPendek juga
      expect(daftar.first.metode, 'PMI Manufaktur');
    });

    test('gabungan = rata-rata skor yang tersedia', () {
      const d = DataMakro(pmi: 56, vix: 35);
      final skor = papan.semua(d).map((s) => s.skor).toList();
      final g = papan.gabungan(d);
      expect(g.skor, closeTo((skor[0] + skor[1]) / 2, 1e-9));
    });
  });
}
