import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ldp_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  test('paging offset+limit dengan trailer lanjutan', () async {
    for (var i = 1; i <= 5; i++) {
      File('${tmp.path}/f$i.txt').writeAsStringSync('x');
    }
    final tool = ListDirTool(workspaceRoot: tmp.path);
    final page1 = await tool.run({
      'path': '.',
      'offset': 1,
      'limit': 2,
    }, ctx());
    expect(page1.isError, isFalse);
    expect(page1.content, contains('f1.txt'));
    expect(page1.content, contains('f2.txt'));
    expect(page1.content, isNot(contains('f3.txt')));
    expect(
      page1.content,
      contains('entri berlanjut; gunakan offset=3'),
    );
    final page2 = await tool.run({
      'path': '.',
      'offset': 3,
      'limit': 2,
    }, ctx());
    expect(page2.isError, isFalse);
    expect(page2.content, contains('f3.txt'));
    expect(page2.content, contains('f4.txt'));
    expect(page2.content, contains('gunakan offset=5'));
    final page3 = await tool.run({
      'path': '.',
      'offset': 5,
      'limit': 2,
    }, ctx());
    expect(page3.isError, isFalse);
    expect(page3.content, contains('f5.txt'));
    expect(page3.content, isNot(contains('entri berlanjut')));
  });

  test('offset melebihi jumlah entri', () async {
    File('${tmp.path}/a.txt').writeAsStringSync('x');
    final tool = ListDirTool(workspaceRoot: tmp.path);
    final r = await tool.run({
      'path': '.',
      'offset': 99,
      'limit': 10,
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('offset melebihi jumlah entri'));
  });
}
