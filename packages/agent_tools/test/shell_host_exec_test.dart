import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  ToolContext ctx(String root) => ToolContext(
        session: Session(id: 's-f1', channel: 'cli', userKey: 'u1'),
        workspacePath: root,
      );

  test('tanpa sandbox & flag off \u2192 shell ditolak fail-closed', () async {
    final root = await Directory.systemTemp.createTemp('tiko_hostoff_');
    try {
      final res = await ShellTool(
        sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: root.path),
      ).run({'cmd': 'echo halo'}, ctx(root.path));
      expect(res.isError, isTrue);
      expect(res.content, contains('sandbox'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('flag on \u2192 argv-exec tanpa interpreter, output & exit nyata', () async {
    final root = await Directory.systemTemp.createTemp('tiko_hoston_');
    File('${root.path}/catatan.txt').writeAsStringSync('isi');
    try {
      final tool = ShellTool(
        sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: root.path),
        allowHostExec: true,
      );
      final ok = await tool.run({'cmd': 'echo halo'}, ctx(root.path));
      expect(ok.isError, isFalse);
      expect(ok.content, contains('halo'));
      expect(ok.content, contains('exit: 0'));

      final cat = await tool.run({'cmd': 'cat catatan.txt'}, ctx(root.path));
      expect(cat.isError, isFalse);
      expect(cat.content, contains('isi'));

      final fail = await tool.run({'cmd': 'ls tidak_ada'}, ctx(root.path));
      expect(fail.isError, isTrue);
      expect(fail.content, contains('exit:'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('flag on tetap tidak melewati jail/metachar PathSafety', () async {
    final root = await Directory.systemTemp.createTemp('tiko_hostjail_');
    try {
      final tool = ShellTool(
        sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: root.path),
        allowHostExec: true,
      );
      final res =
          await tool.run({'cmd': 'cat /etc/passwd'}, ctx(root.path));
      expect(res.isError, isTrue);
      expect(res.content, contains('di luar workspace'));

      final meta =
          await tool.run({'cmd': 'echo a > b.txt'}, ctx(root.path));
      expect(meta.isError, isTrue);
      expect(meta.content, contains('Metacharacter shell dilarang'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
