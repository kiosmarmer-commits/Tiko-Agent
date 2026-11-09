import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _skillMd = '''
---
name: halo demo
description: Skill uji coba promosi durabel.
triggers: ["halo"]
tools: []
version: 1
status: draft
---
## Langkah
- Balas salam dengan sapaan ramah.
''';

/// Menyiapkan config mock + satu skill di <temp>/skills/halo-demo.
/// Nama skill sengaja diawali "halo" agar smoke task fallback gate
/// (answer_contains = kata pertama nama) lolos pada jawaban tetap
/// MockLlmProvider plain.
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
  test('evaluate -> approve -> restart menjaga approval secara durabel',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_skill_appr_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final evaluated = await rt.evaluateSkill('halo-demo');
    expect(evaluated.ok, isTrue, reason: evaluated.message);
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.draft);

    final approved = await rt.approveSkill('halo-demo', actor: 'novan');
    expect(approved.ok, isTrue, reason: approved.message);
    expect(rt.skills.get('halo-demo')!.status, SkillStatus.approved);
    expect(rt.skills.get('halo-demo')!.approvedBy, 'novan');

    await rt.close();

    // Restart: frontmatter masih draft, ledger harus memulihkan approved.
    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    final restored = rt2.skills.get('halo-demo')!;
    expect(restored.status, SkillStatus.approved);
    expect(restored.approvedBy, 'novan');
    expect(restored.goldenTotal, greaterThan(0));

    // Rollback juga durabel: restart berikutnya kembali ke draft.
    final rolled = await rt2.rollbackSkill('halo-demo', actor: 'novan');
    expect(rolled.ok, isTrue);
    expect(rt2.skills.get('halo-demo')!.status, SkillStatus.draft);
    await rt2.close();

    final rt3 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt3.close);
    expect(rt3.skills.get('halo-demo')!.status, SkillStatus.draft);
    await rt3.close();
  });

  test('evaluateSkill dengan slug tidak dikenal melempar ArgumentError',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_skill_unk_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    await expectLater(
      rt.evaluateSkill('tidak-ada'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
