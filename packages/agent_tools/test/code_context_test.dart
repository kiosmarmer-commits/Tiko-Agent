import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CodeContextTool tool;
  late ToolContext ctx;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tiko_codectx_');
    Directory('${root.path}/lib/src').createSync(recursive: true);
    Directory('${root.path}/scripts').createSync(recursive: true);
    File('${root.path}/lib/src/agent_loop.dart').writeAsStringSync('''
class AgentLoop {
  int run(int x) {
    return x;
  }
}

final top = AgentLoop();
''');
    File('${root.path}/lib/main.dart').writeAsStringSync('''
import 'src/agent_loop.dart';

void main() {
  final loop = AgentLoop();
  print(loop);
}
''');
    File('${root.path}/scripts/x.py').writeAsStringSync('''
class PyClass:
    def deploy(self):
        return 1
''');
    tool = CodeContextTool(workspaceRoot: root.path);
    ctx = ToolContext(
      session: Session(id: 's-f2', channel: 'cli', userKey: 'u1'),
      workspacePath: root.path,
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('map: daftar simbol dari dart & python', () async {
    final res = await tool.run({'action': 'map'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('class AgentLoop'));
    expect(res.content, contains('class PyClass'));
    expect(res.content, contains('lib/main.dart'));
  });

  test('find: definisi kelas tertentu', () async {
    final res = await tool.run({'action': 'find', 'symbol': 'AgentLoop'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('lib/src/agent_loop.dart:1:'));
    expect(res.content, isNot(contains('lib/main.dart:')));
  });

  test('refs: referensi word-boundary', () async {
    final res = await tool.run({'action': 'refs', 'symbol': 'AgentLoop'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('lib/main.dart:4:'));
    expect(res.content, contains('lib/src/agent_loop.dart:7:'));
  });

  test('find tanpa simbol / simbol aneh ditolak fail-closed', () async {
    final noSym = await tool.run({'action': 'find'}, ctx);
    expect(noSym.isError, isTrue);

    final bad = await tool.run({'action': 'find', 'symbol': 'a b;c'}, ctx);
    expect(bad.isError, isTrue);
  });

  test('path di luar workspace ditolak', () async {
    final res = await tool.run({'action': 'map', 'path': '../..'}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('path/subdirektori membatasi pemindaian', () async {
    final res = await tool.run({'action': 'find', 'symbol': 'PyClass', 'path': 'lib'}, ctx);
    expect(res.content, contains('tidak ada definisi'));
  });
}
