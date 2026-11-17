import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _skillMd = '''
---
name: halo demo
description: Skill uji anomali token (E1).
triggers: ["halo"]
tools: []
version: 1
status: draft
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
security:
  mode: ask
  token_anomaly:
    enabled: ENABLED
    min_samples: 3
    window_size: 20
    z_multiplier: 3.0
    min_spike_ratio: 3.0
    cooldown_minutes: 0
    max_quarantines_per_day: 1
mcp:
  servers: []
''';

Future<String> _prepare(Directory temp, {required bool enabled}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final skillsDir = await Directory(
    p.join(temp.path, 'skills', 'halo-demo'),
  ).create(recursive: true);
  await File(p.join(skillsDir.path, 'SKILL.md')).writeAsString(_skillMd);
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    _config
        .replaceAll('WORKSPACE', temp.path)
        .replaceAll('DATA', p.join(temp.path, 'data'))
        .replaceAll('ENABLED', enabled ? 'true' : 'false'),
  );
  return config.path;
}

Session _session(String id) =>
    Session(id: id, channel: 'test', userKey: 'tester');

ChatRunResult _turn(int tokens, List<String> skills) => ChatRunResult(
      text: 'ok',
      success: true,
      tokensUsed: tokens,
      skillsUsed: skills,
    );

void main() {
  test('E1: nonaktif (default) -> detektor tidak dibuat', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_ta_off_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp, enabled: false);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.tokenAnomalyDetectorForTest, isNull);
  });

  test('E1: lonjakan token -> skill dikarantina ke draft + event', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_ta_on_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp, enabled: true);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.tokenAnomalyDetectorForTest, isNotNull);

    // Promosikan skill agar karantina (draft) punya efek terukur.
    final approved = await rt.approveSkill('halo-demo', actor: 'tester');
    expect(approved.ok, isTrue, reason: approved.message);
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.approved);

    final session = _session('s-e1');
    // Baseline: 3 giliran normal (min_samples 3) -> tidak ada alarm.
    for (var i = 0; i < 3; i++) {
      await rt.checkTokenAnomalyForTest(session, _turn(100, ['halo-demo']));
    }
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.approved);

    // Lonjakan 10x -> anomali -> karantina.
    await rt.checkTokenAnomalyForTest(session, _turn(1000, ['halo-demo']));
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.draft);
    expect(rt.skills.get('halo-demo')!.approvedBy, isNull);

    // Event tercatat di event bus.
    final events = rt.events.recent(limit: 50);
    expect(
      events.any((e) => e['type'] == 'security.token_anomaly'),
      isTrue,
      reason: 'event security.token_anomaly harus dipancarkan',
    );
    final ev = events.firstWhere((e) => e['type'] == 'security.token_anomaly');
    expect(ev['slug'], 'halo-demo');
    expect(ev['tokens'], 1000);
    expect(ev['quarantined'], isTrue);
  });

  test('E1: cap harian karantina + skill draft dilewati', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_ta_cap_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp, enabled: true);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    // Dua skill tambahan: keduanya akan di-approve.
    final skillsDir = Directory(p.join(temp.path, 'skills', 'halo-dua'));
    await skillsDir.create(recursive: true);
    await File(p.join(skillsDir.path, 'SKILL.md'))
        .writeAsString(_skillMd.replaceAll('halo demo', 'halo dua'));
    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    await rt2.approveSkill('halo-demo', actor: 'tester');
    await rt2.approveSkill('halo-dua', actor: 'tester');

    final session = _session('s-cap');
    // Baseline untuk keduanya.
    for (var i = 0; i < 3; i++) {
      await rt2.checkTokenAnomalyForTest(
          session, _turn(100, ['halo-demo', 'halo-dua']));
    }
    // Dua anomali dalam satu giliran, tapi cap = 1 per hari.
    await rt2.checkTokenAnomalyForTest(
        session, _turn(10000, ['halo-demo', 'halo-dua']));
    final first = rt2.skills.get('halo-demo')!.status;
    final second = rt2.skills.get('halo-dua')!.status;
    // Tepat satu yang dikarantina (iterasi terurut: halo-demo dulu).
    expect(first, SkillStatus.draft);
    expect(second, SkillStatus.approved);
  });
}
