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

/// Data terpisah sempurna: label 1 jika fitur pertama > 0.
/// Fitur kedua = -fitur pertama (juga informatif).
({List<List<double>> x, List<int> y}) dataPisah() {
  final x = <List<double>>[];
  final y = <int>[];
  for (var a = -5.0; a <= 5.0; a += 0.25) {
    x.add([a, -a]);
    y.add(a > 0 ? 1 : 0);
  }
  return (x: x, y: y);
}

void main() {
  group('Pengklasifikasi pada data terpisah', () {
    final d = dataPisah();

    test('KNN', () {
      final m = KNN(k: 5)..latih(d.x, d.y);
      expect(m.peluang([4, -4]), greaterThan(0.8));
      expect(m.peluang([-4, 4]), lessThan(0.2));
    });

    test('PohonKeputusan', () {
      final m = PohonKeputusan(maksKedalaman: 3, minSampelDaun: 2)
        ..latih(d.x, d.y);
      expect(m.peluang([4, -4]), greaterThan(0.8));
      expect(m.peluang([-4, 4]), lessThan(0.2));
    });

    test('HutanAcak', () {
      final m = HutanAcak(jumlahPohon: 30, maksKedalaman: 3, minSampelDaun: 2)
        ..latih(d.x, d.y);
      expect(m.peluang([4, -4]), greaterThan(0.8));
      expect(m.peluang([-4, 4]), lessThan(0.2));
    });

    test('latih dengan data kosong melempar error', () {
      expect(() => KNN().latih([], []), throwsArgumentError);
    });
  });

  group('FiturPasar', () {
    final naik = [for (var i = 0; i < 100; i++) 100 * math.exp(0.01 * i)];
    final f = FiturPasar(candles(naik));

    test('belum cukup data -> null', () {
      expect(f.vektor(10), isNull);
    });

    test('vektor punya jumlah fitur yang benar', () {
      expect(f.vektor(60)!.length, FiturPasar.namaFitur.length);
    });

    test('dataLatih: jumlah sampel dan label tren naik', () {
      final d = f.dataLatih(horizon: 5);
      expect(d.x.length, 45); // indeks 50..94
      expect(d.y.length, 45);
      expect(d.y.every((e) => e == 1), isTrue);
    });
  });

  group('MetodeML', () {
    final naik = [for (var i = 0; i < 300; i++) 100 * math.exp(0.005 * i)];

    test('tren naik konsisten -> beli untuk ketiga model', () {
      for (final m in [
        MetodeML.knn(),
        MetodeML.pohon(),
        MetodeML.hutan(jumlahPohon: 20),
      ]) {
        expect(m.analisis(candles(naik)).arah, Arah.beli, reason: m.nama);
      }
    });

    test('data sedikit -> tahan', () {
      final s = MetodeML.knn().analisis(candles(naik.sublist(0, 80)));
      expect(s.arah, Arah.tahan);
    });
  });
}
