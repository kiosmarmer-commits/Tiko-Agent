import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('patch_file replaces unique snippet', () async {
    final dir = Directory.systemTemp.createTempSync('patch_');
    final f = File('${dir.path}/a.txt')..writeAsStringSync('hello world');
    final tool = PatchFileTool(workspaceRoot: dir.path);
    final session = Session(id: 's', channel: 'cli', userKey: 'u');
    final r = await tool.run({
      'path': 'a.txt',
      'old': 'world',
      'new': 'dart',
    }, ToolContext(session: session, workspacePath: dir.path));
    expect(r.isError, isFalse);
    expect(f.readAsStringSync(), 'hello dart');
    dir.deleteSync(recursive: true);
  });

  test('patch_file replace_all mengganti semua kemunculan', () async {
    final dir = Directory.systemTemp.createTempSync('patch_all_');
    final f = File('${dir.path}/a.txt')
      ..writeAsStringSync('x foo y foo z foo');
    final tool = PatchFileTool(workspaceRoot: dir.path);
    final session = Session(id: 's', channel: 'cli', userKey: 'u');
    final r = await tool.run({
      'path': 'a.txt',
      'old': 'foo',
      'new': 'bar',
      'replace_all': true,
    }, ToolContext(session: session, workspacePath: dir.path));
    expect(r.isError, isFalse);
    expect(f.readAsStringSync(), 'x bar y bar z bar');
    expect(r.content, contains('3 penggantian'));
    expect(r.content, contains('- foo'));
    expect(r.content, contains('+ bar'));
    dir.deleteSync(recursive: true);
  });

  test('patch_file tanpa replace_all menolak old yang tidak unik', () async {
    final dir = Directory.systemTemp.createTempSync('patch_multi_');
    File('${dir.path}/a.txt').writeAsStringSync('foo and foo');
    final tool = PatchFileTool(workspaceRoot: dir.path);
    final session = Session(id: 's', channel: 'cli', userKey: 'u');
    final r = await tool.run({
      'path': 'a.txt',
      'old': 'foo',
      'new': 'bar',
    }, ToolContext(session: session, workspacePath: dir.path));
    expect(r.isError, isTrue);
    expect(r.content, contains('tidak unik'));
    dir.deleteSync(recursive: true);
  });

  test('patch_file menyertakan pratinjau diff pada hasil', () async {
    final dir = Directory.systemTemp.createTempSync('patch_diff_');
    File('${dir.path}/a.txt').writeAsStringSync('alpha\nbeta');
    final tool = PatchFileTool(workspaceRoot: dir.path);
    final session = Session(id: 's', channel: 'cli', userKey: 'u');
    final r = await tool.run({
      'path': 'a.txt',
      'old': 'beta',
      'new': 'gamma',
    }, ToolContext(session: session, workspacePath: dir.path));
    expect(r.isError, isFalse);
    expect(r.content, contains('- beta'));
    expect(r.content, contains('+ gamma'));
    dir.deleteSync(recursive: true);
  });
}
