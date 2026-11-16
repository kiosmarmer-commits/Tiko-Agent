import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const validSkillMd = '''
---
name: hub-demo
description: Demo skill from the hub
allowed-tools:
  - read_file
---

Do the demo thing.
''';

Future<HttpServer> startHubStub() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (req.uri.path == '/api/skills/hub-demo') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'id': 'hub-demo',
        'name': 'hub-demo',
        'description': 'Demo skill from the hub',
        'version': '1.0.0',
        'files': {'SKILL.md': validSkillMd},
      }));
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  });
  return server;
}

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
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
''');
  return config.path;
}

void main() {
  late Directory temp;
  late HttpServer hub;
  late String configPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_hub_reload_');
    hub = await startHubStub();
    configPath = await _prepare(temp);
  });

  tearDown(() async {
    await hub.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('install via tool skills_hub langsung terlihat di SkillRegistry', () async {
    final rt = await TikoRuntime.create(
      configPath: configPath,
      env: {'TIKO_SKILLS_HUB_URL': 'http://127.0.0.1:${hub.port}/api'},
    );
    addTearDown(rt.close);

    expect(rt.registry.get('skills_hub'), isNotNull);
    expect(rt.skills.get('hub-demo'), isNull);

    final tool = rt.registry.get('skills_hub')!;
    final result = await tool.run(
      {'action': 'install', 'id': 'hub-demo'},
      ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: temp.path,
      ),
    );
    expect(result.isError, isFalse);
    expect(result.content, contains('hub-demo'));

    expect(rt.skills.get('hub-demo'), isNotNull,
        reason: 'hot-reload tanpa restart');
    expect(rt.skills.get('hub-demo')!.status, SkillStatus.draft,
        reason: 'skill hub lahir draft — approval gate tetap berlaku');
    expect(File(p.join(temp.path, 'skills', 'hub-demo', 'SKILL.md')).existsSync(),
        isTrue);
  });

  test('uninstall via tool menghapus skill dari registry', () async {
    final rt = await TikoRuntime.create(
      configPath: configPath,
      env: {'TIKO_SKILLS_HUB_URL': 'http://127.0.0.1:${hub.port}/api'},
    );
    addTearDown(rt.close);

    final tool = rt.registry.get('skills_hub')!;
    await tool.run(
      {'action': 'install', 'id': 'hub-demo'},
      ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: temp.path,
      ),
    );
    expect(rt.skills.get('hub-demo'), isNotNull);

    final removed = await tool.run(
      {'action': 'uninstall', 'id': 'hub-demo'},
      ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: temp.path,
      ),
    );
    expect(removed.isError, isFalse);
    expect(rt.skills.get('hub-demo'), isNull,
        reason: 'hot-reload setelah uninstall');
  });
}
