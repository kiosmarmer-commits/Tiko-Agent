import 'dart:math' as math;

import 'package:prediksi/prediksi.dart';
import 'package:test/test.dart';

void main() {
  group('DataFundamental', () {
    const d = DataFundamental(
      harga: 1000,
      labaPerSaham: 100,
      nilaiBukuPerSaham: 800,
      dividenPerSaham: 40,
      pertumbuhanLabaPersen: 10,
    );

    test('rasio dasar', () {
      expect(d.per, closeTo(10, 1e-9));
      expect(d.pbv, closeTo(1.25, 1e-9));
      expect(d.imbalDividen, closeTo(0.04, 1e-9));
      expect(d.peg, closeTo(1, 1e-9));
    });

    test('laba nol -> PER null', () {
      const rugi = DataFundamental(
        harga: 10,
        labaPerSaham: 0,
        nilaiBukuPerSaham: 5,
      );
      expect(rugi.per, isNull);
      expect(rugi.peg, isNull);
    });
  });

  group('AnalisisFundamental', () {
    const af = AnalisisFundamental();

    test('angka Graham dan rumus pertumbuhan', () {
      expect(AnalisisFundamental.angkaGraham(100, 800),
          closeTo(math.sqrt(22.5 * 100 * 800), 1e-9));
      expect(AnalisisFundamental.nilaiGraham(100, 10), closeTo(2850, 1e-9));
      expect(AnalisisFundamental.angkaGraham(-1, 800), isNull);
    });

    test('DCF: arus kas datar 100 dengan diskonto 10% -> perpetuitas 1000', () {
      final v = AnalisisFundamental.dcf(
        arusKasAwal: 100,
        pertumbuhanPersen: 0,
        diskontoPersen: 10,
        pertumbuhanTerminalPersen: 0,
      );
      expect(v, closeTo(1000, 1e-6));
    });

    test('DCF: diskonto <= pertumbuhan terminal -> null', () {
      expect(
        AnalisisFundamental.dcf(
          arusKasAwal: 100,
          pertumbuhanPersen: 5,
          diskontoPersen: 2,
          pertumbuhanTerminalPersen: 2,
        ),
        isNull,
      );
    });

    test('murah dibanding nilai wajar -> beli', () {
      const murah = DataFundamental(
        harga: 1000,
        labaPerSaham: 100,
        nilaiBukuPerSaham: 800,
        pertumbuhanLabaPersen: 10,
      );
      expect(af.sinyal(murah).arah, Arah.beli);
    });

    test('mahal dibanding nilai wajar -> jual', () {
      const mahal = DataFundamental(
        harga: 5000,
        labaPerSaham: 100,
        nilaiBukuPerSaham: 800,
        pertumbuhanLabaPersen: 10,
      );
      expect(af.sinyal(mahal).arah, Arah.jual);
    });

    test('laba negatif -> jual', () {
      const rugi = DataFundamental(
        harga: 100,
        labaPerSaham: -5,
        nilaiBukuPerSaham: 50,
      );
      expect(af.sinyal(rugi).arah, Arah.jual);
    });
  });

  group('Delphi', () {
    const delphi = Delphi();

    test('ringkasan: median dan kuartil', () {
      final r = delphi.ringkas([100, 110, 120, 130, 140]);
      expect(r.median, closeTo(120, 1e-9));
      expect(r.q1, closeTo(110, 1e-9));
      expect(r.q3, closeTo(130, 1e-9));
      expect(r.konsensus, isFalse); // 20/120 > 0.15
    });

    test('putaran berikutnya mengerucut ke median', () {
      final baru = delphi.putaranBerikut([100, 110, 120, 130, 140], tarikan: 0.5);
      expect(baru, [110, 115, 120, 125, 130]);
      expect(delphi.ringkas(baru).konsensus, isTrue);
    });

    test('simulasi: dispersi menurun tiap putaran', () {
      final h = delphi.simulasi([100, 110, 120, 130, 140]);
      expect(h.length, 4);
      for (var i = 1; i < h.length; i++) {
        expect(h[i].dispersi, lessThan(h[i - 1].dispersi));
      }
    });

    test('median berbobot', () {
      expect(Delphi.median([1, 2, 3], bobot: [1, 1, 10]), 3);
    });

    test('bobot tidak sama panjang -> error', () {
      expect(() => Delphi.median([1, 2, 3], bobot: [1, 1]), throwsArgumentError);
    });

    test('sinyal: target pakar jauh di atas harga -> beli', () {
      final s = delphi.sinyal([115, 120, 125], hargaSaatIni: 100);
      expect(s.arah, Arah.beli);
    });

    test('sinyal: estimasi kurang dari 3 -> tahan', () {
      expect(delphi.sinyal([120, 130], hargaSaatIni: 100).arah, Arah.tahan);
    });
  });

  group('PasarPrediksi', () {
    test('normalisasi dan overround', () {
      expect(PasarPrediksi.normalisasi([0.55, 0.55]), [0.5, 0.5]);
      expect(PasarPrediksi.overround([0.55, 0.55]), closeTo(0.1, 1e-9));
    });

    test('probabilitas dari odds desimal', () {
      final p = PasarPrediksi.dariOddsDesimal([1.8, 2.2]);
      expect(p[0], closeTo(0.55, 1e-9));
      expect(p[1], closeTo(0.45, 1e-9));
    });

    test('Brier score', () {
      expect(PasarPrediksi.brierScore([0.9, 0.2], [1, 0]), closeTo(0.025, 1e-9));
    });

    test('sinyal dari probabilitas', () {
      const pm = PasarPrediksi();
      expect(pm.sinyal(0.8).arah, Arah.beli);
      expect(pm.sinyal(0.2).arah, Arah.jual);
      expect(pm.sinyal(0.8, keyakinan: 0.2).arah, Arah.tahan);
    });
  });

  group('LmsrMarket', () {
    test('harga awal sama rata dan total 1', () {
      final m = LmsrMarket(jumlahHasil: 2);
      expect(m.harga[0], closeTo(0.5, 1e-9));
      expect(m.harga.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });

    test('membeli menaikkan harga hasil itu, biaya wajar', () {
      final m = LmsrMarket(jumlahHasil: 2);
      final biaya = m.beli(0, 50);
      expect(biaya, greaterThan(25));
      expect(biaya, lessThan(50));
      expect(m.harga[0], greaterThan(0.5));
      expect(m.harga.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });
  });
}
