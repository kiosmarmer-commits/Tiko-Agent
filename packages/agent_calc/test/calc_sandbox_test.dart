import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const sandbox = CalcSandbox();

  test('sandbox setara engine langsung', () async {
    final r = await sandbox.evaluate('15% dari 2 juta');
    expect(r.ok, isTrue);
    expect(r.value, '300000');
    expect(r.normalizedExpr, '((15)/100)*(2000000)');
    expect(r.approximate, isFalse);
  });

  test('galat berkode melewati sandbox utuh', () async {
    final r = await sandbox.evaluate('1/0');
    expect(r.ok, isFalse);
    expect(r.error?.code, CalcErrorCodes.divZero);
  });

  test('parameter scale dan locale diteruskan ke sandbox', () async {
    final r = await sandbox.evaluate('2/3', scale: 4);
    expect(r.value, '0.6667');
    final r2 = await sandbox.evaluate('1,500.50 * 2', locale: 'en');
    expect(r2.value, '3001');
  });

  test('operasi berat selesai dalam batas default', () async {
    final r = await sandbox.evaluate('fact(5000)');
    expect(r.ok, isTrue);
    expect(r.value!.length, 16326);
    expect(r.value!.startsWith('42285779266055435222'), isTrue);
  });

  test('timeout membatalkan isolat -> CALC_E_TIMEOUT', () async {
    const limits = CalcLimits(timeoutMs: 0);
    final r = await sandbox.evaluate('fact(5000)', limits: limits);
    expect(r.ok, isFalse);
    expect(r.error?.code, CalcErrorCodes.timeout);
  });
}
