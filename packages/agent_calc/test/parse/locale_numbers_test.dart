import 'package:agent_calc/agent_calc.dart';
import 'package:agent_calc/src/parse/locale_numbers.dart';
import 'package:test/test.dart';

LocaleNumbersResult canon(
  String s, {
  String locale = 'id',
  bool strict = false,
}) =>
    LocaleNumbers.canonicalize(s, locale: locale, strict: strict);

void main() {
  test('id: 1.500.000,50 -> 1500000.50 tanpa warning', () {
    final r = canon('1.500.000,50');
    expect(r.text, '1500000.50');
    expect(r.warnings, isEmpty);
  });

  test('id: 1.500 ambigu -> 1500 + W_AMBIGUOUS_NUMBER', () {
    final r = canon('1.500 * 2');
    expect(r.text, '1500 * 2');
    expect(r.warnings, contains('W_AMBIGUOUS_NUMBER'));
  });

  test('id: 3.14 desimal titik -> W_DECIMAL_POINT', () {
    final r = canon('3.14 * 2');
    expect(r.text, '3.14 * 2');
    expect(r.warnings, contains('W_DECIMAL_POINT'));
  });

  test('sufiks: 2 juta, 5rb, 1,5 juta, 3k', () {
    expect(canon('2 juta').text, '2000000');
    expect(canon('5rb * 2').text, '5000 * 2');
    expect(canon('1,5 juta').text, '1500000');
    expect(canon('3k + 1').text, '3000 + 1');
  });

  test('sufiks tidak mencerna koma pemisah argumen', () {
    expect(canon('300, k').text, '300, k');
    expect(canon('2, juta').text, '2, juta');
  });

  test('strict: angka ambigu -> CALC_E_AMBIGUOUS_NUMBER', () {
    expect(
      () => canon('1.500', strict: true),
      throwsA(isA<CalcException>().having(
        (e) => e.code,
        'code',
        CalcErrorCodes.ambiguousNumber,
      )),
    );
  });

  test('en: 1,500.50 -> 1500.50; 1,500 -> 1500; 1.500 tetap', () {
    final r = canon('1,500.50', locale: 'en');
    expect(r.text, '1500.50');
    expect(canon('1,500', locale: 'en').text, '1500');
    expect(canon('1.500', locale: 'en').text, '1.500');
    expect(r.warnings, isEmpty);
  });

  test('en: desimal koma memicu W_DECIMAL_POINT', () {
    final r = canon('2,5 * 2', locale: 'en');
    expect(r.text, '2.5 * 2');
    expect(r.warnings, contains('W_DECIMAL_POINT'));
  });

  test('notasi ilmiah dibiarkan', () {
    expect(canon('1.5e3').text, '1.5e3');
    expect(canon('2E-3 + 1').text, '2E-3 + 1');
  });
}
