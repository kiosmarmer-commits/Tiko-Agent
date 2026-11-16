import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String get _fixturePath {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidates = [
      p.join(dir.path, 'test', 'fixtures', 'line_plugin.dart'),
      p.join(dir.path, 'packages', 'agent_core', 'test', 'fixtures',
          'line_plugin.dart'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    if (dir.path == dir.parent.path) break;
    dir = dir.parent;
  }
  fail('fixture line_plugin.dart tidak ditemukan dari ${Directory.current.path}');
}

ProcessPlugin _spawn(String mode) => ProcessPlugin(
      name: 'line-$mode',
      command: Platform.resolvedExecutable,
      args: [_fixturePath, mode],
      workingDirectory: Directory.current.path,
      hookTimeout: const Duration(seconds: 10),
    );

void main() {
  test('listTools mem-parse deklarasi valid dan melewatkan yang tidak valid',
      () async {
    final plugin = _spawn('tools');
    await plugin.init();
    addTearDown(plugin.dispose);

    final specs = await plugin.listTools();
    expect(specs.map((s) => s.name), ['echo_tool']);
    expect(specs.single.description, 'tool contoh dari plugin');
    expect(specs.single.risk, 'medium');
    expect(specs.single.inputSchema, containsPair('type', 'object'));
  });

  test('invokeTool meneruskan args dan mengembalikan hasil plugin', () async {
    final plugin = _spawn('tools');
    await plugin.init();
    addTearDown(plugin.dispose);

    final (output, isError) = await plugin.invokeTool(
      'echo_tool',
      {'input': 'halo'},
      's1',
    );
    expect(output, 'echo: halo');
    expect(isError, isFalse);
  });

  test('invokeTool untuk tool tak dikenal menghasilkan error', () async {
    final plugin = _spawn('tools');
    await plugin.init();
    addTearDown(plugin.dispose);

    final (output, isError) = await plugin.invokeTool('ngasal', {}, 's1');
    expect(isError, isTrue);
    expect(output, contains('gagal menjalankan tool'));
  });

  test('PluginTool.run membungkus invokeTool; plugin mati -> error result',
      () async {
    final plugin = _spawn('tools');
    await plugin.init();
    final tool = PluginTool(plugin: plugin, declared: (await plugin.listTools()).single);
    expect(tool.spec.name, 'plugin_line_tools_echo_tool');
    expect(tool.spec.risk, 'medium');

    final ctx = ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u1'),
      workspacePath: Directory.current.path,
    );
    final ok = await tool.run({'input': 'x'}, ctx);
    expect(ok.isError, isFalse);
    expect(ok.content, 'echo: x');

    await plugin.dispose();
    final dead = await tool.run({'input': 'x'}, ctx);
    expect(dead.isError, isTrue);
    expect(dead.content, contains('sudah keluar'));
  });

  test('PluginToolSpec.tryParse fail-closed', () {
    expect(PluginToolSpec.tryParse({'name': 'Bad-Name'}), isNull);
    expect(PluginToolSpec.tryParse({'name': ''}), isNull);
    expect(PluginToolSpec.tryParse({'name': 'a', 'risk': 'ngasal'})!.risk,
        'high');
    expect(
      PluginToolSpec.tryParse({'name': 'a', 'input_schema': 'bukan-objek'})!
          .inputSchema,
      {'type': 'object'},
    );
  });

  test('bridgeName men-namespaces per plugin', () {
    expect(PluginTool.bridgeName('my-plugin', 'echo_tool'),
        'plugin_my_plugin_echo_tool');
  });
}
