import 'package:agent_calc/src/parse/rewrite_id.dart';
import 'package:test/test.dart';

void main() {
  test('R1: X% dari Y', () {
    expect(RewriteId.rewrite('15% dari 2 juta'), '((15)/100)*(2 juta)');
  });

  test('R2: naik', () {
    expect(RewriteId.rewrite('100 naik 10%'), '(100)*(1+(10)/100)');
    expect(RewriteId.rewrite('naik 10% dari 200'), '(200)*(1+(10)/100)');
  });

  test('R3: turun dan diskon', () {
    expect(RewriteId.rewrite('100 turun 10%'), '(100)*(1-(10)/100)');
    expect(RewriteId.rewrite('diskon 20% dari 150'), '(150)*(1-(20)/100)');
  });

  test('R4: X adalah berapa persen dari Y', () {
    expect(
      RewriteId.rewrite('30 adalah berapa persen dari 200'),
      '((30)/(200))*100',
    );
  });

  test('R5: akar dari X', () {
    expect(RewriteId.rewrite('akar dari 2'), 'sqrt(2)');
  });

  test('R6: kata operator', () {
    expect(RewriteId.rewrite('5 kali 3'), '(5)*(3)');
    expect(RewriteId.rewrite('10 dibagi 4'), '(10)/(4)');
    expect(RewriteId.rewrite('2 tambah 3'), '(2)+(3)');
    expect(RewriteId.rewrite('10 kurang 4'), '(10)-(4)');
    expect(RewriteId.rewrite('2 pangkat 10'), '(2)^(10)');
  });

  test('frasa berulang ditangani bertahap hingga stabil', () {
    expect(RewriteId.rewrite('2 kali 3 kali 4'), '((2)*(3))*(4)');
  });

  test('bukan frasa dikenal -> null (jangan menebak)', () {
    expect(RewriteId.rewrite('1+2'), isNull);
    expect(RewriteId.rewrite('sqrt(2)'), isNull);
    expect(RewriteId.rewrite('15 * 200'), isNull);
  });
}
