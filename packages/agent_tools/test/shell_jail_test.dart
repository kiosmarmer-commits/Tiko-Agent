import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('shell menolak path sibling dengan prefix workspace sama', () async {
    final root = await Directory.systemTemp.createTemp('tiko_jail_');
    final outsideDir = Directory('${root.path}X')..createSync();
    final secret = File('${outsideDir.path}/secret.txt')
      ..writeAsStringSync('rahasia');
    try {
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'u1'),
        workspacePath: root.path,
      );
      final res = await ShellTool().run({'cmd': 'cat ${secret.path}'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('di luar workspace'));
    } finally {
      await outsideDir.delete(recursive: true);
      await root.delete(recursive: true);
    }
  });

  test('shell menolak path absolut di luar workspace', () async {
    final ctx = ToolContext(
      session: Session(id: 's2', channel: 'cli', userKey: 'u1'),
      workspacePath: Directory.systemTemp.path,
    );
    final res = await ShellTool().run({'cmd': 'cat /etc/passwd'}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('shell menolak traversal dengan ..', () async {
    final root = await Directory.systemTemp.createTemp('tiko_jail2_');
    try {
      final ctx = ToolContext(
        session: Session(id: 's3', channel: 'cli', userKey: 'u1'),
        workspacePath: root.path,
      );
      final res = await ShellTool().run(
        {'cmd': 'cat ../../etc/passwd'},
        ctx,
      );
      expect(res.isError, isTrue);
      expect(res.content, contains('..'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
