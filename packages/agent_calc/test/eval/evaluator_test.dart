import 'package:agent_calc/agent_calc.dart';
import 'package:agent_calc/src/eval/evaluator.dart';
import 'package:agent_calc/src/parse/parser.dart';
import 'package:agent_calc/src/parse/tokenizer.dart';
import 'package:test/test.dart';

Matcher throwsCalcException(String code) => throwsA(
      isA<CalcException>().having((e) => e.code, 'code', code),
    );

Dec evalExpr(String s, {int scale = 12, String angleUnit = 'rad'}) {
  final ast = Parser(const Tokenizer().tokenize(s)).parse();
  final ctx = EvalContext(scale: scale, angleUnit: angleUnit);
  return const Evaluator().eval(ast, ctx);
}

void main() {
  test('G-MAT-004: 3 + 4*2/(1-5)^2^3', () {
    expect(
      evalExpr('3 + 4*2/(1-5)^2^3', scale: 20).toString(),
      '3.0001220703125',
    );
  });

  test('G-MAT-005: sqrt(2) scale 20 eksak', () {
    expect(
      evalExpr('sqrt(2)', scale: 20).toString(),
      '1.41421356237309504880',
    );
  });

  test('presedensi: -2^2 = -4; 10/-1*-2 = 20; 2^3^2 = 512', () {
    expect(evalExpr('-2^2'), Dec.fromInt(-4));
    expect(evalExpr('10/-1*-2'), Dec.fromInt(20));
    expect(evalExpr('2^3^2'), Dec.fromInt(512));
  });

  test('persen: 15% = 0.15; 200+10% = 220; 200-10% = 180', () {
    expect(evalExpr('15%'), Dec.parse('0.15'));
    expect(evalExpr('200+10%'), Dec.parse('220'));
    expect(evalExpr('200-10%'), Dec.parse('180'));
    expect(evalExpr('200*15%'), Dec.parse('30'));
  });

  test('persen +/- memakai basis kiri dan memberi warning', () {
    final ast = Parser(const Tokenizer().tokenize('200+10%')).parse();
    final ctx = EvalContext();
    const Evaluator().eval(ast, ctx);
    expect(ctx.warnings, contains('PERCENT_BASE_LEFT'));
  });

  test('faktorial, kombinatorik, gcd, mod', () {
    expect(evalExpr('5!'), Dec.fromInt(120));
    expect(evalExpr('fact(5)'), Dec.fromInt(120));
    expect(evalExpr('ncr(5,2)'), Dec.fromInt(10));
    expect(evalExpr('npr(5,2)'), Dec.fromInt(20));
    expect(evalExpr('gcd(12,18)'), Dec.fromInt(6));
    expect(evalExpr('lcm(4,6)'), Dec.fromInt(12));
    expect(evalExpr('mod(10,3)'), Dec.fromInt(1));
    expect(evalExpr('10 mod 3'), Dec.fromInt(1));
  });

  test('round default half_up (DEC-OPEN-01); varian eksplisit', () {
    expect(evalExpr('round(1.005, 2)'), Dec.parse('1.01'));
    expect(evalExpr('round_half_even(2.5, 0)'), Dec.fromInt(2));
    expect(evalExpr('round_half_up(2.5, 0)'), Dec.fromInt(3));
    expect(evalExpr('round(2.5, 0)'), Dec.fromInt(3));
  });

  test('galat domain, div-zero, limit', () {
    expect(evalExpr('sqrt(-1)').toString, throwsCalcException);
    expect(() => evalExpr('sqrt(-1)'), throwsCalcException('CALC_E_DOMAIN'));
    expect(() => evalExpr('ln(0)'), throwsCalcException('CALC_E_DOMAIN'));
    expect(() => evalExpr('log(0)'), throwsCalcException('CALC_E_DOMAIN'));
    expect(() => evalExpr('1/0'), throwsCalcException('CALC_E_DIV_ZERO'));
    expect(() => evalExpr('5 mod 0'), throwsCalcException('CALC_E_DIV_ZERO'));
    expect(() => evalExpr('fact(5001)'), throwsCalcException('CALC_E_LIMIT'));
    expect(() => evalExpr('9^9^9'), throwsCalcException('CALC_E_LIMIT'));
  });

  test('simbol tidak dikenal', () {
    expect(
      () => evalExpr('foo(1)'),
      throwsCalcException('CALC_E_UNKNOWN_SYMBOL'),
    );
    expect(() => evalExpr('xyz'), throwsCalcException('CALC_E_UNKNOWN_SYMBOL'));
  });

  test('konstanta menandai approximate', () {
    final ast = Parser(const Tokenizer().tokenize('sin(pi)')).parse();
    final ctx = EvalContext();
    const Evaluator().eval(ast, ctx);
    expect(ctx.approximate, isTrue);
  });

  test('exp(1) dekat konstanta e (15 digit signifikan)', () {
    expect(
      evalExpr('exp(1)', scale: 14).toString(),
      startsWith('2.718281828459'),
    );
  });
}
