import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const engine = CalcEngine();

  CalcResult calc(String s) => engine.evaluate(s);

  test('convert panjang: 5 km -> 5000 m', () {
    final r = calc('convert(5, km, m)');
    expect(r.ok, isTrue);
    expect(r.value, '5000');
  });

  test('convert massa: 2.5 kg -> 2500 g', () {
    final r = calc('convert(2.5, kg, g)');
    expect(r.value, '2500');
  });

  test('convert waktu: 2 jam -> 7200 detik', () {
    final r = calc('convert(2, jam, detik)');
    expect(r.value, '7200');
  });

  test('convert data biner: 2 gib -> 2048 mib', () {
    final r = calc('convert(2, gib, mib)');
    expect(r.value, '2048');
  });

  test('convert sebagai bagian ekspresi', () {
    final r = calc('100 + convert(2, km, m)');
    expect(r.value, '2102');
  });

  test('suhu: c, f, k', () {
    expect(calc('convert(100, c, f)').value, '212');
    expect(calc('convert(0, c, k)').value, '273.15');
    expect(calc('convert(212, f, c)').value, '100');
    expect(calc('convert(300, k, c)').value, '26.85');
  });

  test('satuan tidak dikenal -> CALC_E_UNIT_MISMATCH', () {
    final r = calc('convert(5, xx, m)');
    expect(r.ok, isFalse);
    expect(r.error?.code, CalcErrorCodes.unitMismatch);
  });

  test('satuan beda family -> CALC_E_UNIT_MISMATCH', () {
    final r = calc('convert(5, kg, m)');
    expect(r.error?.code, CalcErrorCodes.unitMismatch);
  });

  test('argumen convert salah -> CALC_E_SYNTAX', () {
    expect(calc('convert(5, km)').error?.code, CalcErrorCodes.syntax);
    expect(calc('convert(5, 2, m)').error?.code, CalcErrorCodes.syntax);
  });
}
