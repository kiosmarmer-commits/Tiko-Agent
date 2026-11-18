import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// GUI-P1-10: Security Center — `securitySnapshot()` mengonsolidasi status
/// keamanan runtime menjadi satu Map read-only (tanpa nilai rahasia).
void main() {
  test('snapshot berisi safety, sandbox, credentials, plugins, token anomaly, guard, audit', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_sec_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'config')).create();
    final config = File(p.join(configDir.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp.path}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
  token_anomaly:
    enabled: true
mcp:
  servers: []
''');

    // Data dir & logs dibuat runtime saat start.
    final rt = await TikoRuntime.create(configPath: config.path, safe: false);
    addTearDown(rt.close);

    // Catat satu entri audit agar audit.recent tidak kosong.
    await rt.audit.log(
      sessionId: 's-1',
      tool: 'datetime',
      args: {'tz': 'UTC'},
      risk: 'low',
      verdict: 'allow',
      resultSummary: 'waktu saat ini',
    );

    final snap = rt.securitySnapshot();
    expect(snap['safety'], isA<Map>());
    expect((snap['safety'] as Map)['safe_mode'], isFalse);
    expect(snap['sandbox'], isA<String>());
    expect(snap['credentials'], isA<Map>());
    expect((snap['credentials'] as Map)['sealed_storage'], isA<bool>());
    expect(snap['plugins'], isA<List>());
    expect((snap['token_anomaly'] as Map)['enabled'], isTrue);
    expect((snap['token_anomaly'] as Map)['quarantines_today'], 0);
    expect((snap['rate_anomaly'] as Map)['max_events'], isA<int>());
    expect((snap['guard'] as Map)['blocked_turns'], 0);
    expect((snap['guard'] as Map)['sanitized_turns'], 0);

    final audit = snap['audit'] as Map;
    expect(audit['total_in_memory'] >= 1, isTrue);
    final recent = audit['recent'] as List;
    expect(recent, isNotEmpty);
    // Entri terbaru dulu, dan TIDAK memuat argumen mentah sensitif
    // (AuditLog sudah meredaksi).
    expect((recent.first as Map)['tool'], 'datetime');
  });

  test('token_anomaly nonaktif: enabled=false dan skills kosong', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_sec_off_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'config')).create();
    final config = File(p.join(configDir.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp.path}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
  token_anomaly:
    enabled: false
mcp:
  servers: []
''');
    final rt = await TikoRuntime.create(configPath: config.path);
    addTearDown(rt.close);

    final snap = rt.securitySnapshot();
    expect((snap['token_anomaly'] as Map)['enabled'], isFalse);
    expect((snap['token_anomaly'] as Map)['skills'], isEmpty);
  });

  test('sampledSlugs menskrip sampel yang dicatat detektor', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_sec_slug_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'config')).create();
    final skillsDir = await Directory(
      p.join(temp.path, 'skills', 'halo-demo'),
    ).create(recursive: true);
    await File(p.join(skillsDir.path, 'SKILL.md')).writeAsString('''
---
name: halo demo
description: uji
triggers: ["halo"]
tools: []
version: 1
status: draft
---
## Langkah
- Balas salam.
''');
    final config = File(p.join(configDir.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp.path}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
  token_anomaly:
    enabled: true
mcp:
  servers: []
''');
    final rt = await TikoRuntime.create(configPath: config.path);
    addTearDown(rt.close);

    await rt.checkTokenAnomalyForTest(
      Session(id: 's-x', channel: 'test', userKey: 'tester'),
      const ChatRunResult(text: 'ok', success: true, tokensUsed: 10, skillsUsed: ['halo-demo']),
    );

    final snap = rt.securitySnapshot();
    final skills = (snap['token_anomaly'] as Map)['skills'] as List;
    expect(skills, hasLength(1));
    expect((skills.first as Map)['slug'], 'halo-demo');
    expect((skills.first as Map)['samples'], 1);
  });
}
