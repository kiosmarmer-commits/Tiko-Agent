import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('skill_feedback_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Skill approvedSkill(String slug) => Skill(
        slug: slug,
        name: slug,
        description: 'test skill',
        body: 'body',
        status: SkillStatus.approved,
      );

  test('applyFeedback memperbarui reliability dan tersink ke ledger durabel',
      () async {
    final path = '${temp.path}/skill_metrics.json';
    final ledger = SkillMetricsLedger(path);
    await ledger.load();

    final registry = SkillRegistry()..register(approvedSkill('deploy'));
    registry.onFeedbackRecorded = ledger.recordFeedback;

    registry.applyFeedback('deploy', positive: true);
    registry.applyFeedback('deploy', positive: true);
    registry.applyFeedback('deploy', positive: false);
    await registry.flushPendingSinks();

    // Fresh ledger reads what the sinks wrote — nothing lost.
    final reloaded = SkillMetricsLedger(path);
    await reloaded.load();
    final m = reloaded.of('deploy');
    expect(m, isNotNull);
    expect(m!.positive, 2);
    expect(m.negative, 1);
  });

  test('feedback tidak pernah mengubah status draft menjadi approved',
      () async {
    final path = '${temp.path}/skill_metrics.json';
    final ledger = SkillMetricsLedger(path);
    await ledger.load();

    final skill = Skill(
      slug: 'draft-skill',
      name: 'draft-skill',
      description: 'test skill',
      body: 'body',
      status: SkillStatus.draft,
    );
    final registry = SkillRegistry()..register(skill);
    registry.onFeedbackRecorded = ledger.recordFeedback;

    registry.applyFeedback('draft-skill', positive: true);
    await registry.flushPendingSinks();

    // Feedback is telemetry only; activation stays with SkillPromotionGate.
    expect(skill.status, SkillStatus.draft);
    expect(skill.approvedBy, isNull);
  });

  test('flushPendingSinks menunggu tulisan yang masih berjalan', () async {
    final registry = SkillRegistry()..register(approvedSkill('slow'));
    var completed = 0;
    registry.onFeedbackRecorded = (slug, {required bool positive}) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      completed++;
    };
    registry.applyFeedback('slow', positive: true);
    expect(completed, 0);
    await registry.flushPendingSinks();
    expect(completed, 1);
  });
}
