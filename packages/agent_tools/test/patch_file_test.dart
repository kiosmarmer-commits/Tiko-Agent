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
}
