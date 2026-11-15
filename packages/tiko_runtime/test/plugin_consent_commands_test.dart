import 'dart:io';

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
}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final perms =
      permissions.isEmpty ? '[]' : '[${permissions.join(", ")}]';
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
      args: ["$fixture", "normal"]
      permissions: $perms
''');
  return config.path;
}

void main() {
  late Directory temp;
  late String fixture;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_plugin_cmd_');
    fixture = _fixturePath();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('plugin tanpa consent tetap pending dan tidak di-spawn', () async {
    final configPath = await _prepare(temp, fixture, permissions: ['tools.read']);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(rt.plugins.length, 0);

    final list = await rt.chat('/plugin list');
    expect(list, contains('contoh'));
    expect(list, contains('menunggu consent'));
    expect(list, contains('tools.read'));

    final info = await rt.chat('/plugin info contoh');
    expect(info, contains('menunggu consent'));
    expect(info, contains('tools.read'));
  });

  test('grant mendaftarkan plugin; revoke mencabutnya', () async {
    final configPath = await _prepare(temp, fixture, permissions: ['tools.read']);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final granted = await rt.chat('/plugin consent contoh grant');
    expect(granted, contains('disetujui dan terdaftar'));
    expect(rt.plugins.has('contoh'), isTrue);

    final list = await rt.chat('/plugin list');
    expect(list, contains('terdaftar'));
    expect(list, contains('tools.read'));

    final revoked = await rt.chat('/plugin consent contoh revoke');
    expect(revoked, contains('dicabut'));
    expect(rt.plugins.has('contoh'), isFalse);
  });

  test('consent persisten: plugin tetap terdaftar setelah restart runtime',
      () async {
    final configPath = await _prepare(temp, fixture, permissions: ['tools.read']);
    final rt = await TikoRuntime.create(configPath: configPath);
    await rt.chat('/plugin consent contoh grant');
    expect(rt.plugins.has('contoh'), isTrue);
    await rt.close();

    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    expect(rt2.plugins.has('contoh'), isTrue);
    final list = await rt2.chat('/plugin list');
    expect(list, contains('contoh [terdaftar'));
  });

  test('aksi consent tidak dikenal ditolak', () async {
    final configPath = await _prepare(temp, fixture, permissions: ['tools.read']);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final out = await rt.chat('/plugin consent contoh haram');
    expect(out, contains('tidak dikenal'));
    expect(out, contains('grant'));
  });
}
