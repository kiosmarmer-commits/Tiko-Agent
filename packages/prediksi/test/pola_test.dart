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

/// Deret harga yang melewati [titik] secara linear, [langkah] titik per segmen.
List<double> jalur(List<double> titik, {int langkah = 10}) {
  final out = <double>[titik.first];
  for (var s = 0; s < titik.length - 1; s++) {
    for (var t = 1; t <= langkah; t++) {
      out.add(titik[s] + (titik[s + 1] - titik[s]) * t / langkah);
    }
  }
  return out;
}

void main() {
  group('zigzag', () {
    test('menemukan pivot bergantian sesuai titik balik', () {
      final pv = zigzag(jalur([100, 120, 108, 150]));
      expect(pv.map((p) => p.harga).toList(), [100, 120, 108, 150]);
      expect(pv.map((p) => p.tinggi).toList(), [false, true, false, true]);
    });

    test('gerakan di bawah ambang diabaikan', () {
      final pv = zigzag(jalur([100, 102, 101, 103]), ambang: 0.05);
      expect(pv, isEmpty);
    });

    test('data terlalu pendek -> kosong', () {
      expect(zigzag([100]), isEmpty);
    });
  });

  group('DowTheory', () {
    const dow = DowTheory();

    test('higher high + higher low -> naik', () {
      final d = candles(jalur([100, 120, 110, 135, 122, 150]));
      expect(dow.tren(d), TrenDow.naik);
      expect(dow.analisis(d).arah, Arah.beli);
    });

    test('lower high + lower low -> turun', () {
      final d = candles(jalur([150, 130, 140, 115, 125, 100]));
      expect(dow.tren(d), TrenDow.turun);
      expect(dow.analisis(d).arah, Arah.jual);
    });

    test('puncak naik tetapi lembah turun -> menyamping', () {
      final d = candles(jalur([100, 120, 95, 130, 90, 140]));
      expect(dow.tren(d), TrenDow.menyamping);
      expect(dow.analisis(d).arah, Arah.tahan);
    });

    test('konfirmasi dua indeks', () {
      final naik = candles(jalur([100, 120, 110, 135, 122, 150]));
      final turun = candles(jalur([150, 130, 140, 115, 125, 100]));
      expect(dow.konfirmasi(naik, naik).skor, closeTo(0.9, 1e-9));
      expect(dow.konfirmasi(naik, turun).arah, Arah.tahan);
    });
  });

  group('ElliottWave', () {
    const ew = ElliottWave();

    test('gelombang 1-2 selesai -> gelombang 3 diperkirakan (bullish)', () {
      final pola = ew.deteksi(candles(jalur([100, 120, 108])))!;
      expect(pola.jumlahPivot, 3);
      expect(pola.naik, isTrue);
      expect(pola.skor, closeTo(0.6, 1e-9));
    });

    test('gelombang 1-4 selesai -> gelombang 5 diperkirakan', () {
      final pola = ew.deteksi(candles(jalur([100, 120, 108, 150, 135])))!;
      expect(pola.jumlahPivot, 5);
      expect(pola.skor, closeTo(0.35, 1e-9));
    });

    test('lima gelombang naik selesai -> koreksi diperkirakan (bearish)', () {
      final d = candles(jalur([100, 120, 108, 150, 135, 165]));
      final pola = ew.deteksi(d)!;
      expect(pola.jumlahPivot, 6);
      expect(pola.skor, closeTo(-0.5, 1e-9));
      expect(ew.analisis(d).arah, Arah.jual);
    });

    test('lima gelombang turun selesai -> pantulan diperkirakan', () {
      final d = candles(jalur([200, 180, 192, 150, 165, 135]));
      final pola = ew.deteksi(d)!;
      expect(pola.naik, isFalse);
      expect(pola.skor, closeTo(0.5, 1e-9));
      expect(ew.analisis(d).arah, Arah.beli);
    });

    test('gelombang 4 menimpa wilayah gelombang 1 -> bukan impuls 5 pivot', () {
      // p4 = 115 < p1 = 120 melanggar aturan tumpang tindih.
      final pola = ew.deteksi(candles(jalur([100, 120, 108, 150, 115])));
      expect(pola?.jumlahPivot, isNot(5));
    });

    test('tanpa pola -> tahan', () {
      final d = candles(jalur([100, 101, 100, 101]));
      expect(ew.analisis(d).arah, Arah.tahan);
    });
  });
}
