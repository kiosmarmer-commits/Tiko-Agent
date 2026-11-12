import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const engine = CalcEngine();

  CalcResult calc(String s) => engine.evaluate(s);

  test('pmt bunga nol: 1200 / 12 periode', () {
    expect(calc('pmt(0, 12, 1200)').value, '100');
  });

  test('pmt anuitas eksak pada skala 12', () {
    expect(calc('pmt(0.01, 12, 100000)').value, '8884.878867834171');
  });

  test('annuity_fv dan annuity_pv eksak', () {
    expect(
      calc('annuity_fv(0.01, 12, 100)').value,
      '1268.250301319697',
    );
    expect(
      calc('annuity_pv(0.01, 12, 100)').value,
      '1125.507747348463',
    );
  });

  test('amortisasi: total bunga sepanjang tenor', () {
    expect(
      calc('amortisasi(0.01, 12, 1000000)').value,
      '66185.464140100484',
    );
  });

  test('sisa pinjaman k=0 dan k=6', () {
    expect(calc('sisa(0.01, 12, 1000000, 0)').value, '1000000');
    expect(
      calc('sisa(0.01, 12, 1000000, 6)').value,
      '514921.064580199444',
    );
  });

  test('irr sederhana dekat 10% (perkiraan)', () {
    final r = calc('irr(-1000, 1100)');
    expect(r.ok, isTrue);
    expect(r.approximate, isTrue);
    expect(double.parse(r.value!), closeTo(0.1, 1e-9));
  });

  test('irr multi periode (perkiraan)', () {
    final r = calc('irr(-1000, 400, 400, 400, 300)');
    expect(r.ok, isTrue);
    expect(double.parse(r.value!), closeTo(0.193, 0.001));
  });

  test('irr tanpa akar -> CALC_E_NO_CONVERGENCE', () {
    final r = calc('irr(100, 100)');
    expect(r.ok, isFalse);
    expect(r.error?.code, CalcErrorCodes.noConvergence);
  });

  test('periode tidak bulat -> CALC_E_DOMAIN', () {
    final r = calc('pmt(0.01, 2.5, 1000)');
    expect(r.error?.code, CalcErrorCodes.domain);
  });
}
