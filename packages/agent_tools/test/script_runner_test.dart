import 'dart:convert';
import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('custom script tools stay disabled without an OS sandbox', () async {
    final dir = Directory.systemTemp.createTempSync('tiko-script-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final toolDir = Directory('${dir.path}/example')..createSync();
    File('${toolDir.path}/tool.json').writeAsStringSync(jsonEncode({
      'name': 'example',
      'runtime': {'command': ['python3', 'run.py']},
      'risk': 'high',
    }));
    final runner = ScriptToolRunner(toolsDir: dir.path);
    expect(await runner.loadAll(), isEmpty);
  });

  test('script loader ignores tool definitions reached through symlinks', () async {
    final root = Directory.systemTemp.createTempSync('tiko-script-root-');
    final tools = Directory('${root.path}/tools')..createSync();
    final outside = Directory.systemTemp.createTempSync('tiko-script-outside-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
      if (outside.existsSync()) await outside.delete(recursive: true);
    });

    final externalTool = Directory('${outside.path}/escaped')..createSync();
    File('${externalTool.path}/tool.json').writeAsStringSync(jsonEncode({
      'name': 'escaped',
      'runtime': {'command': ['python3', 'run.py']},
      'risk': 'high',
    }));
    await Link('${tools.path}/escaped').create(externalTool.path);

    final runner = ScriptToolRunner(
      toolsDir: tools.path,
      sandbox: SandboxRunner(kind: SandboxKind.bubblewrap, workspacePath: root.path),
    );
    expect(await runner.loadAll(), isEmpty);
  });


  test('script tools receive a private workspace without project secrets', () async {
    final root = Directory.systemTemp.createTempSync('tiko-script-private-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final tools = Directory('${root.path}/tools')..createSync();
    final workspaceTool = Directory('${tools.path}/example')..createSync();
    File('${workspaceTool.path}/tool.json').writeAsStringSync(jsonEncode({
      'name': 'example',
      'description': 'isolated example',
      'runtime': {'command': ['python3', 'run.py']},
      'risk': 'high',
    }));
    File('${workspaceTool.path}/run.py').writeAsStringSync('print("ok")');
    File('${workspaceTool.path}/.env').writeAsStringSync('TOKEN=do-not-copy');
    final git = Directory('${workspaceTool.path}/.git')..createSync();
    File('${git.path}/config').writeAsStringSync('private git metadata');

    final runner = ScriptToolRunner(
      toolsDir: tools.path,
      sandbox: SandboxRunner(
        kind: SandboxKind.bubblewrap,
        workspacePath: root.path,
      ),
    );
    final loaded = await runner.loadAll();
    expect(loaded, hasLength(1));
    final tool = loaded.single;
    expect(tool.workingDirectory, isNot(workspaceTool.path));
    expect(tool.sandbox.workspacePath, tool.workingDirectory);
    expect(File('${tool.workingDirectory}/run.py').existsSync(), isTrue);
    expect(File('${tool.workingDirectory}/.env').existsSync(), isFalse);
    expect(File('${tool.workingDirectory}/.git/config').existsSync(), isFalse);
    final privatePath = tool.workingDirectory;

    await runner.close();
    expect(Directory(privatePath).existsSync(), isFalse);
    expect(File('${workspaceTool.path}/run.py').existsSync(), isTrue);
  });

  test('script definitions reject unsafe tool names and oversized timeout', () {
    final sandbox = SandboxRunner(workspacePath: Directory.current.path);
    expect(
      () => ScriptTool.fromJson(
        {'name': 'bad-name'},
        Directory.current.path,
        sandbox: sandbox,
      ),
      throwsFormatException,
    );
    expect(
      () => ScriptTool.fromJson(
        {'name': 'ok', 'timeout_sec': 999},
        Directory.current.path,
        sandbox: sandbox,
      ),
      throwsFormatException,
    );
  });
}
