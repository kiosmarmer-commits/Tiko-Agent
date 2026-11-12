import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('probe_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  test('outline markdown dan estimasi token', () async {
    File('${tmp.path}/doc.md')
        .writeAsStringSync('# Atas\n\nintro\n\n## Bawah\n\nisi\n');
    final tool = ProbeTool(workspaceRoot: tmp.path);
    final r = await tool.run({'path': 'doc.md'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('# Atas'));
    expect(r.content, contains('# Bawah'));
    expect(r.content, contains('tokens_est'));
  });

  test('outline simbol dart', () async {
    File('${tmp.path}/a.dart')
        .writeAsStringSync('class Foo {}\nenum Bar { x }\nvoid main() {}\n');
    final tool = ProbeTool(workspaceRoot: tmp.path);
    final r = await tool.run({'path': 'a.dart'}, ctx());
    expect(r.content, contains('class Foo'));
    expect(r.content, contains('enum Bar'));
  });

  test('kolom csv', () async {
    File('${tmp.path}/t.csv').writeAsStringSync('nama,umpan\nA,1\n');
    final tool = ProbeTool(workspaceRoot: tmp.path);
    final r = await tool.run({'path': 't.csv'}, ctx());
    expect(r.content, contains('columns: nama, umpan'));
  });

  test('file besar: head terpotong dan saran rentang', () async {
    final big = List.filled(20000, 'abcdefgh').join('\n');
    File('${tmp.path}/big.txt').writeAsStringSync(big);
    final tool = ProbeTool(workspaceRoot: tmp.path);
    final r = await tool.run({'path': 'big.txt'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('"head_truncated":true'));
    expect(r.content, contains('offset'));
  });

  test('file tidak ada', () async {
    final tool = ProbeTool(workspaceRoot: tmp.path);
    final r = await tool.run({'path': 'nope.md'}, ctx());
    expect(r.isError, isTrue);
  });
}
