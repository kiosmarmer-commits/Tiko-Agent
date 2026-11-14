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
      expect(res.content, contains('di luar workspace'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('nilai flag --file=/etc/passwd ditolak (B-09)', () async {
    final ctx = ToolContext(
      session: Session(id: 's4', channel: 'cli', userKey: 'u1'),
      workspacePath: Directory.systemTemp.path,
    );
    final res = await ShellTool().run({'cmd': 'cat --file=/etc/passwd'}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('flag boolean tanpa nilai tetap lolos jail', () async {
    final root = await Directory.systemTemp.createTemp('tiko_jail3_');
    try {
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/a.txt').writeAsStringSync('isi');
      final ctx = ToolContext(
        session: Session(id: 's5', channel: 'cli', userKey: 'u1'),
        workspacePath: root.path,
      );
      final res = await ShellTool().run({'cmd': 'ls -la sub'}, ctx);
      expect(res.content, isNot(contains('di luar workspace')));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('symlink keluar workspace ditolak', () async {
    final root = await Directory.systemTemp.createTemp('tiko_jail4_');
    final outside = await Directory.systemTemp.createTemp('tiko_jail4_out_');
    try {
      File('${outside.path}/secret.txt').writeAsStringSync('rahasia');
      await Link('${root.path}/leak')
          .create(outside.path, recursive: true);
      final ctx = ToolContext(
        session: Session(id: 's6', channel: 'cli', userKey: 'u1'),
        workspacePath: root.path,
      );
      final res = await ShellTool().run({'cmd': 'cat leak/secret.txt'}, ctx);
      expect(res.isError, isTrue);
      expect(res.content, contains('di luar workspace'));
    } finally {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });
}
