import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('ledger round-trip record dan memangkas ke 500 terbaru', () async {
    final temp = await Directory.systemTemp.createTemp('skill_ledger_');
    addTearDown(() => temp.delete(recursive: true));
    final path = p.join(temp.path, 'skill_approvals.json');

    final ledger = SkillApprovalLedger(path);
    await ledger.load();
    expect(ledger.records, isEmpty);

    for (var i = 0; i < 520; i++) {
      await ledger.append(SkillLedgerRecord(
        slug: 'skill-${i % 4}',
        action: 'evaluated',
        actor: 'tester',
        fingerprint: 'fp-$i',
        at: DateTime.utc(2026, 11, 9, 12, i % 60),
        goldenScore: 1,
        goldenTotal: 1,
      ));
    }
    expect(ledger.records.length, 500);
    expect(ledger.latest('skill-0')!.fingerprint, 'fp-516');

    final reloaded = SkillApprovalLedger(path);
    await reloaded.load();
    expect(reloaded.records.length, 500);
    expect(reloaded.latest('skill-3')!.fingerprint, 'fp-519');
    expect(reloaded.latest('missing'), isNull);
  });

  test('file ledger korup gagal tertutup (semua skill tetap draft)', () async {
    final temp = await Directory.systemTemp.createTemp('skill_ledger_bad_');
    addTearDown(() => temp.delete(recursive: true));
    final path = p.join(temp.path, 'skill_approvals.json');
    await File(path).writeAsString('[not json');

    final ledger = SkillApprovalLedger(path);
    await ledger.load();
    expect(ledger.records, isEmpty);
  });

  test('applyTo memulihkan status durabel hanya saat fingerprint cocok',
      () async {
    final temp = await Directory.systemTemp.createTemp('skill_ledger_apply_');
    addTearDown(() => temp.delete(recursive: true));
    final skillsDir = p.join(temp.path, 'skills');
    final skillDir = Directory(p.join(skillsDir, 'halo-demo'))
      ..createSync(recursive: true);
    File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('''
---
name: halo demo
description: Skill uji coba ledger.
triggers: ["halo"]
tools: []
version: 1
status: approved
---
## Langkah
- Balas salam.
''');

    final registry = SkillRegistry();
    await registry.loadFromDirectory(skillsDir);
    final skill = registry.get('halo-demo')!;
    // Status frontmatter YAML tidak dipercaya sebagai record approval.
    expect(skill.status, SkillStatus.draft);

    final ledger = SkillApprovalLedger(p.join(temp.path, 'ledger.json'));
    await ledger.load();

    // Fingerprint tidak cocok -> tetap draft.
    await ledger.append(SkillLedgerRecord(
      slug: 'halo-demo',
      action: 'approved',
      actor: 'novan',
      fingerprint: 'deadbeef',
      at: DateTime.utc(2026, 11, 9),
      goldenScore: 1,
      goldenTotal: 1,
    ));
    ledger.applyTo(registry);
    expect(skill.status, SkillStatus.draft);

    // Fingerprint cocok -> approved + actor + skor golden pulih.
    await ledger.append(SkillLedgerRecord(
      slug: 'halo-demo',
      action: 'approved',
      actor: 'novan',
      fingerprint: SkillApprovalLedger.fingerprintOf(skill),
      at: DateTime.utc(2026, 11, 9),
      goldenScore: 3,
      goldenTotal: 3,
    ));
    ledger.applyTo(registry);
    expect(skill.status, SkillStatus.approved);
    expect(skill.approvedBy, 'novan');
    expect(skill.goldenScore, 3);
    expect(skill.goldenTotal, 3);

    // Rollback terakhir menang: status kembali draft pada apply berikutnya.
    await ledger.append(SkillLedgerRecord(
      slug: 'halo-demo',
      action: 'rolled_back',
      actor: 'novan',
      fingerprint: SkillApprovalLedger.fingerprintOf(skill),
      at: DateTime.utc(2026, 11, 9),
      reason: 'draft',
    ));
    ledger.applyTo(registry);
    expect(skill.status, SkillStatus.draft);
    expect(skill.approvedBy, isNull);
  });

  test('fingerprint berubah saat konten skill berubah', () {
    final a = Skill(slug: 'x', name: 'x', description: 'd', body: 'b');
    final b = Skill(slug: 'x', name: 'x', description: 'd', body: 'b2');
    expect(
      SkillApprovalLedger.fingerprintOf(a),
      isNot(SkillApprovalLedger.fingerprintOf(b)),
    );
  });
}
