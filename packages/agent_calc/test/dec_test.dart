import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  group('Dec.parse', () {
    test('menerima bentuk valid', () {
      expect(Dec.parse('0').toString(), '0');
      expect(Dec.parse('-1.50').toString(), '-1.50');
      expect(Dec.parse('+12').toString(), '12');
      expect(Dec.parse('.5').toString(), '0.5');
      expect(Dec.parse(' 2.25 ').toString(), '2.25');
    });

    test('menolak bentuk tidak valid', () {
      expect(() => Dec.parse(''), throwsFormatException);
      expect(() => Dec.parse('-'), throwsFormatException);
      expect(() => Dec.parse('1.2.3'), throwsFormatException);
      expect(() => Dec.parse('abc'), throwsFormatException);
      expect(() => Dec.parse('1,5'), throwsFormatException);
      expect(() => Dec.parse('1e3'), throwsFormatException);
    });
  });

  test('eksak: 0.1 + 0.2 == 0.3 (G-MAT-001)', () {
    final r = Dec.parse('0.1') + Dec.parse('0.2');
    expect(r.toString(), '0.3');
  });

  test('half_even: 2.5 -> 2, 3.5 -> 4', () {
    expect(
      Dec.parse('2.5').roundTo(0, RoundingMode.halfEven).toString(),
      '2',
    );
    expect(
      Dec.parse('3.5').roundTo(0, RoundingMode.halfEven).toString(),
      '4',
    );
  });

  test('half_up: 1.005 scale 2 -> 1.01 (G-MAT-006)', () {
    expect(
      Dec.parse('1.005').roundTo(2, RoundingMode.halfUp).toString(),
      '1.01',
    );
  });

  test('bagi eksplisit: 1/3 scale 10 half_even -> 0.3333333333', () {
    final r = Dec.one.divide(
      Dec.fromInt(3),
      scale: 10,
      mode: RoundingMode.halfEven,
    );
    expect(r.toString(), '0.3333333333');
  });

  test('bagi eksplisit: 2/3 scale 4 half_even -> 0.6667', () {
    final r = Dec.fromInt(2).divide(
      Dec.fromInt(3),
      scale: 4,
      mode: RoundingMode.halfEven,
    );
    expect(r.toString(), '0.6667');
  });

  test('bagi dengan nol ditolak', () {
    expect(
      () => Dec.one.divide(Dec.zero, scale: 2, mode: RoundingMode.halfUp),
      throwsFormatException,
    );
  });

  test('floor/ceiling mengikuti tanda nilai', () {
    expect(
      Dec.parse('-2.5').roundTo(0, RoundingMode.floor).toString(),
      '-3',
    );
    expect(
      Dec.parse('-2.5').roundTo(0, RoundingMode.ceiling).toString(),
      '-2',
    );
    expect(
      Dec.parse('2.5').roundTo(0, RoundingMode.floor).toString(),
      '2',
    );
    expect(
      Dec.parse('2.5').roundTo(0, RoundingMode.ceiling).toString(),
      '3',
    );
  });

  test('PROP-02: sifat aljabar eksak', () {
    final a = Dec.parse('0.1');
    final b = Dec.parse('0.2');
    final c = Dec.parse('0.3');
    expect((a + b) - b, a);
    expect(a * b, b * a);
    expect(a * (b + c), a * b + a * c);
  });

  test('PROP-04: sisa pembagian dalam batas half_even', () {
    final a = Dec.fromInt(10);
    final b = Dec.fromInt(3);
    final q = a.divide(b, scale: 6, mode: RoundingMode.halfEven);
    final diff = ((q * b) - a).abs();
    final bound = Dec.parse('0.0000015');
    expect(diff.compareTo(bound) <= 0, isTrue);
  });

  test('PROP-03: bilangan bulat sama dengan BigInt murni', () {
    final a = Dec.fromInt(123456789);
    final b = Dec.fromInt(987654321);
    expect(
      (a * b).unscaled,
      BigInt.from(123456789) * BigInt.from(987654321),
    );
    expect((a * b).scale, 0);
  });

  test('powInt eksak', () {
    expect(Dec.fromInt(2).powInt(10).toString(), '1024');
    expect(Dec.parse('1.5').powInt(2).toString(), '2.25');
    expect(Dec.fromInt(7).powInt(0).toString(), '1');
    expect(() => Dec.fromInt(2).powInt(-1), throwsFormatException);
  });

  test('persamaan berbasis nilai, bukan representasi', () {
    expect(Dec.parse('1.50'), Dec.parse('1.5'));
    expect(Dec.parse('0.30').hashCode, Dec.parse('0.3').hashCode);
    expect(Dec.parse('-0'), Dec.parse('0'));
  });

  test('RoundingMode dari nama kanonik', () {
    expect(RoundingMode.fromName('half_even'), RoundingMode.halfEven);
    expect(RoundingMode.halfUp.wireName, 'half_up');
    expect(
      () => RoundingMode.fromName('HALF_EVEN'),
      throwsFormatException,
    );
  });
}
