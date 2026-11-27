import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _skillMd = '''
---
name: halo demo
description: Skill uji alur feedback (LEARN-01).
triggers: ["halo"]
tools: []
version: 1
status: approved
---
## Langkah
- Balas salam dengan sapaan ramah.
''';

const _config = '''
profile: default
workspace: WORKSPACE
data_dir: DATA
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
mcp:
  servers: []
''';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final skillsDir = await Directory(
    p.join(temp.path, 'skills', 'halo-demo'),
  ).create(recursive: true);
  await File(p.join(skillsDir.path, 'SKILL.md')).writeAsString(_skillMd);
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    _config
        .replaceAll('WORKSPACE', temp.path)
        .replaceAll('DATA', p.join(temp.path, 'data')),
  );
  return config.path;
}

void main() {
  test('LEARN-01: feedback skill tersink durabel dan bertahan restart runtime',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_learn01_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt1 = await TikoRuntime.create(configPath: configPath);
    expect(rt1.skills.get('halo-demo'), isNotNull);
    rt1.skills.applyFeedback('halo-demo', positive: true);
    rt1.skills.applyFeedback('halo-demo', positive: true);
    rt1.skills.applyFeedback('halo-demo', positive: false);
    await rt1.skills.flushPendingSinks();
    await rt1.close();

    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    final metrics = rt2.skillMetrics.metrics['halo-demo'];
    expect(metrics, isNotNull);
    expect(metrics!.positive, 2);
    expect(metrics.negative, 1);
  });

  test('LEARN-01: skill feedback dari CLI tersink ke ledger (skills feedback)',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_learn01_cli_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    rt.skills.applyFeedback('halo-demo', positive: false);
    await rt.skills.flushPendingSinks();
    final metrics = rt.skillMetrics.metrics['halo-demo'];
    expect(metrics, isNotNull);
    expect(metrics!.negative, 1);
    expect(metrics.positive, 0);
  });
}
