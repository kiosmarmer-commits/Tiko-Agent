import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _skillMd = '''
---
name: halo demo
description: Skill uji coba metrik durabel.
triggers: ["halo"]
tools: []
version: 1
status: draft
---
## Langkah
- Balas salam dengan sapaan ramah.
''';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final skillsDir = await Directory(
    p.join(temp.path, 'skills', 'halo-demo'),
  ).create(recursive: true);
  await File(p.join(skillsDir.path, 'SKILL.md')).writeAsString(_skillMd);
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    TikoConfig.setupYaml(provider: 'mock', workspace: temp.path),
  );
  return config.path;
}

void main() {
  test('chat memakai skill, uses terpersist, restart memulihkan', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_skill_metrics_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt = await TikoRuntime.create(configPath: configPath);
    final approved = await rt.approveSkill('halo-demo', actor: 'novan');
    expect(approved.ok, isTrue, reason: approved.message);
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.approved);

    await rt.chat('halo novan');

    // Sink fire-and-forget: tunggu (polling, maks 1 detik) sampai ledger
    // menulis file di dataDir.
    final metricsFile = File(p.join(rt.dataDir, 'skill_metrics.json'));
    var tries = 0;
    while (!metricsFile.existsSync() && tries < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tries++;
    }
    expect(metricsFile.existsSync(), isTrue);
    final ledger = SkillMetricsLedger(metricsFile.path);
    await ledger.load();
    expect(ledger.of('halo-demo')!.uses, greaterThan(0));

    await rt.close();

    // Restart: registry mulai dari nol, ledger harus memulihkan uses.
    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    expect(rt2.skills.get('halo-demo')!.uses, greaterThan(0));
    expect(rt2.skillMetrics.of('halo-demo')!.uses, greaterThan(0));
    await rt2.close();
  });
}
