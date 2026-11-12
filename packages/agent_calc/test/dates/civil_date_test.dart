import 'package:agent_calc/agent_calc.dart';
import 'package:test/test.dart';

void main() {
  const engine = CalcEngine();

  CalcResult calc(String s) => engine.evaluate(s);

  test('date_diff tahun biasa dan kabisat', () {
    expect(calc('date_diff(20260101, 20260301)').value, '59');
    expect(calc('date_diff(20240101, 20240301)').value, '60');
  });

  test('date_add lintas bulan dan kabisat', () {
    expect(calc('date_add(20260131, 1)').value, '20260201');
    expect(calc('date_add(20240228, 1)').value, '20240229');
    expect(calc('date_add(20260228, 1)').value, '20260301');
    expect(calc('date_add(20260101, -1)').value, '20251231');
  });

  test('date_add_months clamp akhir bulan', () {
    expect(calc('date_add_months(20260131, 1)').value, '20260228');
    expect(calc('date_add_months(20260331, -1)').value, '20260228');
    expect(calc('date_add_months(20240229, 12)').value, '20250228');
  });

  test('day_of_week ISO: 1=Senin..7=Minggu', () {
    expect(calc('day_of_week(20261108)').value, '7');
    expect(calc('day_of_week(20260105)').value, '1');
    expect(calc('day_of_week(19700101)').value, '4');
  });

  test('is_leap_year dan days_in_month', () {
    expect(calc('is_leap_year(2024)').value, '1');
    expect(calc('is_leap_year(1900)').value, '0');
    expect(calc('is_leap_year(2000)').value, '1');
    expect(calc('days_in_month(2024, 2)').value, '29');
    expect(calc('days_in_month(2025, 2)').value, '28');
  });

  test('tanggal tidak valid -> CALC_E_DOMAIN', () {
    expect(
      calc('date_diff(20250229, 20260101)').error?.code,
      CalcErrorCodes.domain,
    );
    expect(
      calc('days_in_month(2024, 13)').error?.code,
      CalcErrorCodes.domain,
    );
    expect(
      calc('date_add(99991231, 1)').error?.code,
      CalcErrorCodes.domain,
    );
  });
}
