import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('approve blocked without golden', () {
    final gate = SkillPromotionGate(minGoldenRatio: 0.8);
    final skill = Skill(
      slug: 'x',
      name: 'X',
      description: 'd',
      body: 'b',
    );
    final r = gate.approve(skill, actor: 'test');
    expect(r.ok, isFalse);
  });

  test('promotion fails closed without a real runtime evaluator', () async {
    final gate = SkillPromotionGate(minGoldenRatio: 0.5);
    final skill = Skill(
      slug: 'ringkas-waktu',
      name: 'ringkas waktu',
      description: 'ringkas waktu tool',
      body: 'gunakan datetime',
      triggers: ['waktu'],
    );
    final ev = await gate.evaluateAndMaybePromote(
      skill,
      tasks: [
        GoldenTask(id: 't1', input: 'waktu', mustCallTools: ['datetime'], weight: 1),
      ],
    );
    expect(ev.ok, isFalse);
    expect(ev.stage, 'golden_runtime_unavailable');
    expect(gate.approve(skill, actor: 'test').ok, isFalse);
    expect(skill.status, SkillStatus.draft);
  });

  test('actual golden runtime results allow explicit approval', () async {
    final gate = SkillPromotionGate(
      minGoldenRatio: 0.5,
      evaluator: (tasks) async => [
        GoldenResult(
          taskId: 't1',
          passed: true,
          score: 1,
          answer: 'waktu saat ini',
          toolsCalled: ['datetime'],
        ),
      ],
    );
    final skill = Skill(
      slug: 'ringkas-waktu',
      name: 'ringkas waktu',
      description: 'ringkas waktu tool',
      body: 'gunakan datetime',
      triggers: ['waktu'],
    );
    final ev = await gate.evaluateAndMaybePromote(
      skill,
      tasks: [
        GoldenTask(id: 't1', input: 'waktu', mustCallTools: ['datetime'], weight: 1),
      ],
    );
    expect(ev.ok, isTrue);
    expect(ev.stage, 'evaluated');
    final ap = gate.approve(skill, actor: 'test');
    expect(ap.ok, isTrue);
    expect(skill.status, SkillStatus.approved);
  });
  test('approval is invalidated when a skill changes after golden evaluation', () async {
    final gate = SkillPromotionGate(
      minGoldenRatio: 0.5,
      evaluator: (tasks) async => tasks.map((task) => GoldenResult(
        taskId: task.id,
        passed: true,
        score: task.weight,
      )).toList(),
    );
    final skill = Skill(
      slug: 'mutable-skill',
      name: 'mutable skill',
      description: 'safe description',
      body: 'original body',
    );
    final result = await gate.evaluateAndMaybePromote(
      skill,
      tasks: [GoldenTask(id: 't1', input: 'test')],
    );
    expect(result.ok, isTrue);
    skill.goldenScore = skill.goldenScore + 0.1;
    expect(gate.approve(skill, actor: 'tester').ok, isFalse);
  });

  test('evaluator errors and missing task results fail closed', () async {
    final throwing = SkillPromotionGate(
      evaluator: (_) async => throw StateError('runner unavailable'),
    );
    final skill = Skill(slug: 'runner', name: 'runner', description: 'd', body: 'b');
    final tasks = [GoldenTask(id: 't1', input: 'test')];
    final failed = await throwing.evaluateAndMaybePromote(skill, tasks: tasks);
    expect(failed.stage, 'golden_execution_error');
    expect(throwing.approve(skill, actor: 'tester').ok, isFalse);

    final incomplete = SkillPromotionGate(evaluator: (_) async => const <GoldenResult>[]);
    final missing = await incomplete.evaluateAndMaybePromote(skill, tasks: tasks);
    expect(missing.ok, isFalse);
    expect(incomplete.approve(skill, actor: 'tester').ok, isFalse);
  });

}
