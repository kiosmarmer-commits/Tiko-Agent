import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const engine = CalcEngine();

  test('format Indonesia penuh: 15% dari 2 juta', () {
    final r = engine.evaluate('15% dari 2 juta');
    expect(r.ok, isTrue);
    expect(r.value, '300000');
    expect(r.display, '300.000');
    expect(r.normalizedExpr, '((15)/100)*(2000000)');
    expect(r.approximate, isFalse);
  });

  test('parameter scale dan rounding', () {
    final r = engine.evaluate('2/3', scale: 4);
    expect(r.value, '0.6667');
    expect(r.precision['rounding'], 'half_even');
    final r2 = engine.evaluate('2/3', scale: 4, rounding: RoundingMode.down);
    expect(r2.value, '0.6666');
  });

  test('warning locale terbawa ke hasil', () {
    final r = engine.evaluate('1.500 * 2');
    expect(r.value, '3000');
    expect(r.warnings, contains('W_AMBIGUOUS_NUMBER'));
  });

  test('simbol Unicode dinormalisasi: 6 kali-Unicode 7', () {
    final r = engine.evaluate('6 × 7');
    expect(r.value, '42');
  });

  test('galat berkode: div-zero, domain, limit, panjang', () {
    expect(engine.evaluate('1/0').error?.code, CalcErrorCodes.divZero);
    expect(engine.evaluate('sqrt(-1)').error?.code, CalcErrorCodes.domain);
    expect(engine.evaluate('ln(0)').error?.code, CalcErrorCodes.domain);
    expect(engine.evaluate('9^9^9').error?.code, CalcErrorCodes.limit);
    final long = '1' + List.filled(600, ' + 1').join();
    expect(engine.evaluate(long).error?.code, CalcErrorCodes.limit);
  });

  test('galat sintaks berposisi', () {
    final r = engine.evaluate('2 +');
    expect(r.ok, isFalse);
    expect(r.error?.code, CalcErrorCodes.syntax);
    expect(r.error?.position, 3);
  });

  test('hasil perkiraan ditandai approximate', () {
    final r = engine.evaluate('sin(pi)');
    expect(r.ok, isTrue);
    expect(r.approximate, isTrue);
  });

  test('JSON keluaran mematuhi kontrak', () {
    final text = engine.evaluate('2+3').toJsonText();
    expect(text, contains('"ok":true'));
    expect(text, contains('"value":"5"'));
    expect(text, contains('"normalized_expr":"2+3"'));
    final errText = engine.evaluate('foo(1)').toJsonText();
    expect(errText, contains('"ok":false'));
    expect(errText, contains('CALC_E_UNKNOWN_SYMBOL'));
  });

  test('locale en membalik peran titik dan koma', () {
    final r = engine.evaluate('1,500.50 * 2', locale: 'en');
    expect(r.value, '3001');
  });

  test('display memakai pemisah locale', () {
    final r = engine.evaluate('1500000.5');
    expect(r.display, '1.500.000,5');
  });
}
