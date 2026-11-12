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

/// Urutan 3 langkah x 2 fitur. Label ditentukan fitur pertama di langkah akhir.
List<double> urutan(math.Random rnd, bool positif) {
  final out = <double>[];
  for (var t = 0; t < 3; t++) {
    final f0 = t == 2 ? (positif ? 1.0 : -1.0) : rnd.nextDouble() * 2 - 1;
    out
      ..add(f0)
      ..add(rnd.nextDouble() * 2 - 1);
  }
  return out;
}

void main() {
  group('LstmBiner', () {
    test('belajar pola sederhana: contoh positif > contoh negatif', () {
      final rnd = math.Random(3);
      final x = <List<double>>[];
      final y = <int>[];
      for (var i = 0; i < 120; i++) {
        final pos = rnd.nextBool();
        x.add(urutan(rnd, pos));
        y.add(pos ? 1 : 0);
      }
      final m = LstmBiner(
        panjangUrutan: 3,
        tersembunyi: 6,
        epoch: 60,
        ukuranBatch: 8,
      )..latih(x, y);

      final pPos = m.peluang([0, 0, 0, 0, 1, 0]);
      final pNeg = m.peluang([0, 0, 0, 0, -1, 0]);
      expect(pPos, inExclusiveRange(0, 1));
      expect(pNeg, inExclusiveRange(0, 1));
      expect(pPos, greaterThan(pNeg));
    });

    test('hasil bisa diulang dengan benih sama', () {
      final rnd = math.Random(5);
      final x = [for (var i = 0; i < 40; i++) urutan(rnd, i.isEven)];
      final y = [for (var i = 0; i < 40; i++) i.isEven ? 1 : 0];
      LstmBiner buat() =>
          LstmBiner(panjangUrutan: 3, tersembunyi: 4, epoch: 5)..latih(x, y);
      expect(buat().peluang(x.first), buat().peluang(x.first));
    });

    test('panjang vektor bukan kelipatan panjangUrutan -> error', () {
      expect(
        () => LstmBiner(panjangUrutan: 3).latih([[1, 2, 3, 4]], [1]),
        throwsArgumentError,
      );
    });

    test('belum dilatih -> 0.5', () {
      expect(LstmBiner(panjangUrutan: 3).peluang([1, 2, 3]), 0.5);
    });
  });

  group('MetodeLSTM', () {
    test('data sedikit -> tahan', () {
      final naik = [for (var i = 0; i < 80; i++) 100 * math.exp(0.005 * i)];
      expect(const MetodeLSTM().analisis(candles(naik)).arah, Arah.tahan);
    });

    test('tren naik konsisten -> beli', () {
      final naik = [for (var i = 0; i < 300; i++) 100 * math.exp(0.005 * i)];
      final s = const MetodeLSTM(epoch: 20, maksLatih: 150).analisis(candles(naik));
      expect(s.arah, Arah.beli);
    });
  });
}
