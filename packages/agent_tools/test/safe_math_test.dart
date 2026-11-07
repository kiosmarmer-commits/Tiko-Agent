import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  group('SafeMath', () {
    test('5+1 -> 6 (PRD acceptance #3)', () {
      expect(SafeMath.calculate('5+1'), '6');
    });
    test('precedence, parentheses, spaces', () {
      expect(SafeMath.calculate(' 2 + 3 * 4 '), '14');
      expect(SafeMath.calculate('(2+3)*4'), '20');
    });
    test('integer-valued division prints as int', () {
      expect(SafeMath.calculate('4/2'), '2');
      expect(SafeMath.calculate('10/4'), '2.5');
    });
    test('unary minus and plus', () {
      expect(SafeMath.calculate('-(2+3)'), '-5');
      expect(SafeMath.calculate('2*-3'), '-6');
      expect(SafeMath.calculate('+4'), '4');
    });
    test('power and modulo', () {
      expect(SafeMath.calculate('2^10'), '1024');
      expect(SafeMath.calculate('2^-1'), '0.5');
      expect(SafeMath.calculate('7%3'), '1');
    });
    test('errors are FormatException', () {
      for (final bad in ['1/0', '5%0', '((', '1.2.3', 'abc', '2+', '', '1+(2']) {
        expect(() => SafeMath.calculate(bad), throwsFormatException, reason: bad);
      }
    });
    test('input length and nesting are bounded', () {
      expect(() => SafeMath.calculate('${"1+" * 200}1'), throwsFormatException);
      expect(
        () => SafeMath.calculate('${"(" * 100}1${")" * 100}'),
        throwsFormatException,
      );
    });
  });
}
