import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late GrepTool tool;
  late String root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko_grep_');
    root = tmp.path;
    tool = GrepTool(workspaceRoot: root);
    File('$root/alpha.dart').writeAsStringSync(
      'void main() {\n  // TODO perbaiki ini\n}\n',
    );
    File('$root/notes.txt').writeAsStringSync('TODO tulis ulang\n');
    Directory('$root/sub').createSync();
    File('$root/sub/gamma.dart').writeAsStringSync(
      'final a = 1;\n// todo kecil di sub\nfinal b = 2;\n',
    );
    Directory('$root/.git').createSync();
    File('$root/.git/hidden.dart').writeAsStringSync('// TODO rahasia\n');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(
    session: Session(id: 's1', channel: 'cli', userKey: 'u1'),
    workspacePath: root,
  );

  test('menemukan kecocokan lintas file, lewati .git', () async {
    final res = await tool.run(
      {'pattern': 'TODO', 'case_sensitive': false},
      ctx(),
    );
    expect(res.isError, isFalse);
    expect(res.content, contains('alpha.dart:2'));
    expect(res.content, contains('notes.txt:1'));
    expect(res.content, contains('sub/gamma.dart:2'));
    expect(res.content, isNot(contains('.git')));
  });

  test('glob memfilter tipe file', () async {
    final res = await tool.run(
      {'pattern': 'todo', 'glob': '*.dart', 'case_sensitive': false},
      ctx(),
    );
    expect(res.content, contains('alpha.dart'));
    expect(res.content, contains('gamma.dart'));
    expect(res.content, isNot(contains('notes.txt')));
  });

  test('context_lines menampilkan baris tetangga', () async {
    final res = await tool.run(
      {'pattern': 'todo', 'context_lines': 1, 'case_sensitive': false},
      ctx(),
    );
    expect(res.content, contains('-sub/gamma.dart:1'));
    expect(res.content, contains('-sub/gamma.dart:3'));
  });

  test('regex tidak valid menghasilkan error', () async {
    final res = await tool.run({'pattern': '('}, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('Regex tidak valid'));
  });

  test('tanpa kecocokan memberi ringkasan', () async {
    final res = await tool.run({'pattern': 'NOMATCHXYZ'}, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('Tidak ada kecocokan'));
  });

  test('max_results memotong hasil', () async {
    final res = await tool.run(
      {'pattern': 'TODO', 'case_sensitive': false, 'max_results': 1},
      ctx(),
    );
    expect(res.content, contains('dipotong'));
  });
}
