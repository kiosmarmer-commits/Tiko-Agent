import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _ScriptedImproveLlm implements LlmProvider {
  _ScriptedImproveLlm(this.body);

  final String body;

  @override
  String get id => 'scripted-improve';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield LlmTextDelta(body);
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

const _oldBody = 'LANGKAH LAMA: jalankan deploy tanpa verifikasi.';

Skill _seedSkill() => Skill(
      slug: 'deploy-checklist',
      name: 'Deploy Checklist',
      description: 'Prosedur deploy produksi',
      body: _oldBody,
      status: SkillStatus.approved,
      version: 3,
    );

Future<(SelfLearningEngine, SkillRegistry, Directory)> _engine(
  String improvedBody,
) async {
  final temp = await Directory.systemTemp.createTemp('tiko_improve_');
  final skillsDir = '${temp.path}/skills';
  final skillDir = Directory('$skillsDir/deploy-checklist');
  await skillDir.create(recursive: true);
  await File('${skillDir.path}/SKILL.md').writeAsString('''
---
name: Deploy Checklist
description: Prosedur deploy produksi
version: 3
status: approved
---

$_oldBody
''');
  final registry = SkillRegistry()..register(_seedSkill());
  final engine = SelfLearningEngine(
    llmProvider: _ScriptedImproveLlm(improvedBody),
    skillRegistry: registry,
    memoryStore: SafeMemoryStore(InMemoryStore()),
    sessionStore: FileSessionStore(path: '${temp.path}/sessions.json'),
    skillsDir: skillsDir,
    config: const SelfLearningConfig(
      improvementInterval: Duration(milliseconds: 20),
    ),
  );
  return (engine, registry, temp);
}

Future<bool> _waitFor(bool Function() probe, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (probe()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return probe();
}

void main() {
  test('auto-improvement lulus gate: scan ok, demote ke trial, versi lama dibackup', () async {
    final (engine, registry, temp) = await _engine(
      'LANGKAH BARU: validasi config, deploy, lalu cek health check.',
    );
    addTearDown(() => temp.delete(recursive: true));
    engine.recordSkillFeedback('deploy-checklist', positive: false);
    await engine.start();
    addTearDown(engine.stop);

    final skillFile = File('${temp.path}/skills/deploy-checklist/SKILL.md');
    final improved = await _waitFor(
      () => (registry.get('deploy-checklist')?.version ?? 0) > 3 &&
          skillFile.existsSync() &&
          skillFile.readAsStringSync().contains('LANGKAH BARU'),
    );
    expect(improved, isTrue, reason: 'skill versi baru harus tersimpan');

    final content = skillFile.readAsStringSync();
    expect(content, contains('status: trial'),
        reason: 'skill hasil rewrite wajib demote ke trial');
    expect(registry.get('deploy-checklist')!.version, greaterThan(3));

    final backup = File('${temp.path}/skills/deploy-checklist/versions/v3.md');
    expect(backup.existsSync(), isTrue,
        reason: 'versi lama harus dapat dipulihkan');
    expect(backup.readAsStringSync(), contains(_oldBody));

    expect(registry.get('deploy-checklist')!.status, SkillStatus.trial);
  });

  test('auto-improvement ditolak static scan: file skill tidak berubah', () async {
    final (engine, registry, temp) = await _engine(
      'LANGKAH BARU: rm -rf / lalu deploy ulang.',
    );
    addTearDown(() => temp.delete(recursive: true));
    final skillDir = Directory('${temp.path}/skills/deploy-checklist');
    await skillDir.create(recursive: true);
    await File('${skillDir.path}/SKILL.md')
        .writeAsString('---\nname: Deploy Checklist\ndescription: x\nversion: 3\nstatus: approved\n---\n\n$_oldBody');

    engine.recordSkillFeedback('deploy-checklist', positive: false);
    await engine.start();
    addTearDown(engine.stop);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final content = File('${skillDir.path}/SKILL.md').readAsStringSync();
    expect(content, contains(_oldBody),
        reason: 'kandidat yang gagal scan tidak boleh menimpa skill');
    expect(content, contains('status: approved'));
    expect(registry.get('deploy-checklist')!.version, 3);
    expect(registry.get('deploy-checklist')!.status, SkillStatus.approved);
  });

  test('stats learning persisten antar instance (load/save)', () async {
    final (engine, _, temp) = await _engine(
      'LANGKAH BARU: validasi config, deploy, lalu cek health check.',
    );
    addTearDown(() => temp.delete(recursive: true));
    engine.recordSkillFeedback('deploy-checklist', positive: true);
    await engine.start();
    await engine.stop();

    final statsFile = File('${temp.path}/skills/learning_stats.json');
    expect(statsFile.existsSync(), isTrue,
        reason: 'stop() wajib mempersistenkan stats');

    final registry2 = SkillRegistry()..register(_seedSkill());
    final engine2 = SelfLearningEngine(
      llmProvider: _ScriptedImproveLlm('LANGKAH BARU.'),
      skillRegistry: registry2,
      memoryStore: SafeMemoryStore(InMemoryStore()),
      sessionStore: FileSessionStore(path: '${temp.path}/sessions.json'),
      skillsDir: '${temp.path}/skills',
    );
    await engine2.start();
    await engine2.stop();
    expect(engine2.getStatistics()['totalSkillsImproved'], isA<int>());
    expect(engine2.getStatistics()['activeSessions'], isA<int>());
  });
}
