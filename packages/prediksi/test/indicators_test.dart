import 'package:prediksi/prediksi.dart';
import 'package:test/test.dart';

void main() {
  test('SMA periode 3', () {
    final hasil = Indikator.sma([1, 2, 3, 4, 5], 3);
    expect(hasil[0].isNaN, isTrue);
    expect(hasil[2], closeTo(2, 1e-9));
    expect(hasil[4], closeTo(4, 1e-9));
  });

  test('EMA memakai seed SMA', () {
    final hasil = Indikator.ema([1, 2, 3, 4, 5], 3);
    expect(hasil[2], closeTo(2, 1e-9));
    expect(hasil[3], closeTo(3, 1e-9));
  });

  test('RSI = 100 jika harga naik terus', () {
    final naik = List<double>.generate(30, (i) => 100 + i.toDouble());
    expect(Indikator.rsi(naik).last, closeTo(100, 1e-9));
  });

  test('Fibonacci 50% di tengah', () {
    final f = Indikator.fibonacci(100, 200);
    expect(f['50%'], closeTo(150, 1e-9));
    expect(f['0%'], closeTo(200, 1e-9));
    expect(f['100%'], closeTo(100, 1e-9));
  });

  test('MathUtils.korelasi sempurna', () {
    expect(MathUtils.korelasi([1, 2, 3], [2, 4, 6]), closeTo(1, 1e-9));
  });
}
