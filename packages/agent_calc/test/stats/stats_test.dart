import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const engine = CalcEngine();

  CalcResult calc(String s) => engine.evaluate(s);

  test('median ganjil dan genap', () {
    expect(calc('median(3, 1, 2)').value, '2');
    expect(calc('median(4, 1, 3, 2)').value, '2.5');
  });

  test('mean alias avg', () {
    expect(calc('mean(2, 4)').value, '3');
  });

  test('varians populasi dan sampel', () {
    expect(calc('var_p(2, 4, 4, 4, 5, 5, 7, 9)').value, '4');
    expect(
      calc('var_s(2, 4, 4, 4, 5, 5, 7, 9)').value,
      '4.571428571429',
    );
  });

  test('simpangan baku', () {
    expect(calc('stdev_p(2, 4, 4, 4, 5, 5, 7, 9)').value, '2');
    expect(
      calc('stdev_s(2, 4, 4, 4, 5, 5, 7, 9)').value,
      '2.138089935299',
    );
  });

  test('persentil interpolasi linear', () {
    expect(calc('percentile(1, 2, 3, 4, 90)').value, '3.7');
    expect(calc('percentile(10, 20, 30, 50)').value, '20');
    expect(calc('percentile(1, 2, 3, 4, 0)').value, '1');
    expect(calc('percentile(1, 2, 3, 4, 100)').value, '4');
  });

  test('varians sampel 1 data -> CALC_E_DOMAIN', () {
    final r = calc('var_s(5)');
    expect(r.error?.code, CalcErrorCodes.domain);
  });

  test('persentil di luar 0..100 -> CALC_E_DOMAIN', () {
    final r = calc('percentile(1, 2, 101)');
    expect(r.error?.code, CalcErrorCodes.domain);
  });
}
