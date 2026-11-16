import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

String _fixturePath() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = p.join(
      dir.path,
      'packages',
      'agent_core',
      'test',
      'fixtures',
      'line_plugin.dart',
    );
    if (File(candidate).existsSync()) return candidate;
    if (dir.path == dir.parent.path) break;
    dir = dir.parent;
  }
  fail('fixture line_plugin.dart tidak ditemukan dari ${Directory.current.path}');
}

Future<String> _prepare(
  Directory temp,
  String fixture, {
  required List<String> permissions,
  String mode = 'tools',
}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final perms = permissions.isEmpty ? '[]' : '[${permissions.join(", ")}]';
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 4
plugins:
  process:
    - name: contoh
      command: ${Platform.resolvedExecutable}
      args: ["$fixture", "$mode"]
      permissions: $perms
''');
  return config.path;
}

void main() {
  late Directory temp;
  late String fixture;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_plugin_tool_');
    fixture = _fixturePath();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
      'permission tools.register: tool plugin masuk registry host setelah grant',
      () async {
    final configPath =
        await _prepare(temp, fixture, permissions: ['tools.register']);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(rt.registry.get('plugin_contoh_echo_tool'), isNull,
        reason: 'plugin masih menunggu consent');

    final granted = await rt.chat('/plugin consent contoh grant');
    expect(granted, contains('disetujui dan terdaftar'));

    final tool = rt.registry.get('plugin_contoh_echo_tool');
    expect(tool, isNotNull);
    expect(tool!.spec.risk, 'medium');
    expect(
      rt.registry.names.where((n) => n.contains('Invalid')),
      isEmpty,
      reason: 'deklarasi tidak valid dilewati',
    );

    final result = await tool.run(
      {'input': 'dari-host'},
      ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: temp.path,
      ),
    );
    expect(result.isError, isFalse);
    expect(result.content, 'echo: dari-host');
  });

  test('tanpa permission tools.register: plugin terdaftar tapi tool tidak',
      () async {
    final configPath =
        await _prepare(temp, fixture, permissions: ['tools.read']);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final granted = await rt.chat('/plugin consent contoh grant');
    expect(granted, contains('disetujui dan terdaftar'));
    expect(rt.plugins.has('contoh'), isTrue);

    expect(rt.registry.get('plugin_contoh_echo_tool'), isNull,
        reason: 'tools.register tidak diberikan — fail-closed');
  });

  test('plugin tanpa permission: auto-terdaftar, tool tetap tidak terdaftar',
      () async {
    final configPath = await _prepare(temp, fixture, permissions: []);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(rt.plugins.has('contoh'), isTrue);
    expect(rt.registry.get('plugin_contoh_echo_tool'), isNull);
  });
}
