import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(id: 's', channel: 'cli', userKey: 'u');

  ToolContext ctx() => ToolContext(session: session, workspacePath: '.');

  test('15% dari 2 juta -> 300000 dengan display Indonesia', () async {
    final r = await CalcTool().run(
      {'expression': '15% dari 2 juta'},
      ctx(),
    );
    expect(r.isError, isFalse);
    expect(r.content, contains('"value":"300000"'));
    expect(r.content, contains('"display":"300.000"'));
    expect(r.content, contains('"normalized_expr":"((15)/100)*(2000000)"'));
  });

  test('galat pembagian nol -> isError + CALC_E_DIV_ZERO', () async {
    final r = await CalcTool().run({'expression': '1/0'}, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('CALC_E_DIV_ZERO'));
  });

  test('scale dan rounding diteruskan ke engine', () async {
    final r = await CalcTool().run(
      {'expression': '2/3', 'scale': 4, 'rounding': 'half_up'},
      ctx(),
    );
    expect(r.content, contains('"value":"0.6667"'));
    expect(r.content, contains('"precision":{"scale":4,"rounding":"half_up"}'));
  });

  test('locale en membalik peran titik dan koma', () async {
    final r = await CalcTool().run(
      {'expression': '1,500.50 * 2', 'locale': 'en'},
      ctx(),
    );
    expect(r.content, contains('"value":"3001"'));
  });

  test('expression kosong -> isError', () async {
    final r = await CalcTool().run({'expression': ' '}, ctx());
    expect(r.isError, isTrue);
  });

  test('batas panjang ekspresi -> CALC_E_LIMIT', () async {
    final r = await CalcTool().run(
      {'expression': '1${List.filled(600, ' + 1').join()}'},
      ctx(),
    );
    expect(r.isError, isTrue);
    expect(r.content, contains('CALC_E_LIMIT'));
  });
}
