import 'package:agent_calc/agent_calc.dart';
import 'package:agent_calc/src/parse/ast.dart';
import 'package:agent_calc/src/parse/parser.dart';
import 'package:agent_calc/src/parse/tokenizer.dart';
import 'package:test/test.dart';

Node parse(String s) => Parser(const Tokenizer().tokenize(s)).parse();

void main() {
  test('presedensi: 1+2 terurai sebagai BinaryNode +', () {
    final b = parse('1+2') as BinaryNode;
    expect(b.op, '+');
    expect((b.left as NumNode).value.toString(), '1');
    expect((b.right as NumNode).value.toString(), '2');
  });

  test('pangkat asosiatif kanan: 2^3^2 = 2^(3^2)', () {
    final b = parse('2^3^2') as BinaryNode;
    expect(b.op, '^');
    expect(b.left, isA<NumNode>());
    expect((b.right as BinaryNode).op, '^');
  });

  test('persen postfix menjadi operand kanan +/-', () {
    final b = parse('200+10%') as BinaryNode;
    expect(b.op, '+');
    expect(b.right, isA<PercentNode>());
    expect(parse('15%'), isA<PercentNode>());
  });

  test('faktorial postfix dan panggilan fungsi multi-argumen', () {
    expect(parse('5!'), isA<FactorialNode>());
    final c = parse('sqrt(2, 3)') as CallNode;
    expect(c.name, 'sqrt');
    expect(c.args.length, 2);
  });

  test('kata kunci mod sebagai operator', () {
    final b = parse('5 mod 2') as BinaryNode;
    expect(b.op, 'mod');
  });

  test('notasi ilmiah diterima', () {
    final n = parse('1.5e3') as NumNode;
    expect(n.value.toString(), '1500');
  });

  test('galat: ekspresi tidak lengkap berposisi di akhir', () {
    try {
      parse('2 +');
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.syntax);
      expect(e.position, 3);
    }
  });

  test('galat: kurung tidak seimbang memberi hint', () {
    try {
      parse('(1+2');
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.syntax);
      expect(e.hint, contains(')'));
    }
  });

  test('galat: perkalian implisit ditolak dengan hint', () {
    try {
      parse('2(3)');
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.syntax);
      expect(e.hint, contains('2*3'));
    }
  });

  test('galat: dua angka berurutan ditolak', () {
    try {
      parse('2 3');
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.syntax);
    }
  });

  test('galat: kedalaman bersarang melebihi batas', () {
    final input = '${'(' * 65}1${')' * 65}';
    try {
      parse(input);
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.limit);
    }
  });

  test('galat: karakter lebar penuh ditolak dengan hint ASCII', () {
    try {
      parse('５＋５');
      fail('seharusnya melempar');
    } on CalcException catch (e) {
      expect(e.code, CalcErrorCodes.syntax);
      expect(e.hint, contains('ASCII'));
    }
  });
}
