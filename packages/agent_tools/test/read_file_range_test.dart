import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rfr_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  test('rentang baris offset+limit', () async {
    File('${tmp.path}/a.txt')
        .writeAsStringSync('satu\ndua\ntiga\nempat\n');
    final tool = ReadFileTool(workspaceRoot: tmp.path);
    final r = await tool.run({
      'path': 'a.txt',
      'offset':  2,
      'limit': 2,
    }, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('dua'));
    expect(r.content, contains('tiga'));
    expect(r.content, isNot(contains('satu')));
    expect(r.content, contains('[baris 2-3 dari 4]'));
  });

  test('file besar tetap terbaca per rentang', () async {
    final lines = List.generate(20000, (i) => 'line-$i');
    File('${tmp.path}/big.txt').writeAsStringSync(lines.join('\n'));
    final tool = ReadFileTool(workspaceRoot: tmp.path);
    final full = await tool.run({'path': 'big.txt'}, ctx());
    expect(full.isError, isTrue);
    final ranged = await tool.run({
      'path': 'big.txt',
      'offset': 20000,
      'limit': 5,
    }, ctx());
    expect(ranged.isError, isFalse);
    expect(ranged.content, contains('line-19999'));
    expect(ranged.content, contains('[baris 20000-20000 dari 20000]'));
  });
}
