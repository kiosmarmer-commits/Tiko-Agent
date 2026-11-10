import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  test('CalcLimits default sesuai CALC-ARC-06', () {
    const l = CalcLimits.defaults;
    expect(l.maxExpressionLength, 2000);
    expect(l.maxAstDepth, 64);
    expect(l.maxPowerExponent, 10000);
    expect(l.maxFactorial, 5000);
    expect(l.maxListLength, 100000);
    expect(l.maxHorizon, 365);
    expect(l.timeoutMs, 2000);
  });

  test('CalcException membawa kode, posisi, dan hint', () {
    const e = CalcException(
      CalcErrorCodes.syntax,
      'Kurung tidak seimbang',
      position: 7,
      hint: "Tambahkan ')' sebelum akhir ekspresi",
    );
    expect(e.code, 'CALC_E_SYNTAX');
    expect(e.position, 7);
    expect(e.hint, contains('Tambahkan'));
    expect(e.toString(), startsWith('CALC_E_SYNTAX:'));
  });
}
