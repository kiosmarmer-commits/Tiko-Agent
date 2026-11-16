import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

class _StubLlm extends LlmProvider {
  _StubLlm(this.response);
  final String response;

  @override
  String get id => 'stub';

  @override
  Capabilities get capabilities => const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield LlmTextDelta(response);
  }
}

Skill _skill(String slug, {SkillStatus status = SkillStatus.approved}) =>
    Skill(
      slug: slug,
      name: slug,
      description: 'test skill',
      body: '# $slug',
      status: status,
    );

void main() {
  group('computeDeterministicReward', () {
    test('successful clean turn with positive feedback scores 1.0', () {
      final r = computeDeterministicReward(
        success: true,
        errorCount: 0,
        toolCalls: 3,
        feedback: true,
      );
      expect(r, closeTo(1.0, 0.001));
    });

    test('failed turn with all tool errors scores 0.0', () {
      final r = computeDeterministicReward(
        success: false,
        errorCount: 3,
        toolCalls: 3,
        feedback: false,
      );
      expect(r, closeTo(0.0, 0.001));
    });

    test('missing feedback is neutral, not punishing', () {
      final r = computeDeterministicReward(
        success: true,
        errorCount: 0,
        toolCalls: 2,
        feedback: null,
      );
      expect(r, closeTo(0.6 + 0.25 + 0.075, 0.001));
    });
  });

  group('SelfRewardJudge.parseVerdict', () {
    test('parses valid output', () {
      final v = SelfRewardJudge.parseVerdict(
        'SCORE: 0.85\nREASON: partially correct',
      );
      expect(v, isNotNull);
      expect(v!.$1, closeTo(0.85, 0.001));
      expect(v.$2, contains('partially'));
    });

    test('rejects missing score', () {
      expect(SelfRewardJudge.parseVerdict('looks great to me'), isNull);
    });

    test('rejects out-of-range score', () {
      expect(SelfRewardJudge.parseVerdict('SCORE: 1.5\nREASON: x'), isNull);
    });
  });

  group('TrajectoryLedger', () {
    test('persists records across reload', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final path = '${dir.path}/ledger.jsonl';
      final l1 = TrajectoryLedger(path: path);
      await l1.add(
        TrajectoryRecord(
          id: 'a',
          createdAt: DateTime.utc(2026),
          sessionId: 's',
          success: true,
          skillSlug: 'k',
          toolCalls: const ['x'],
        ),
      );
      final l2 = TrajectoryLedger(path: path);
      expect(l2.length, 1);
      expect(l2.records.first.skillSlug, 'k');
      await dir.delete(recursive: true);
    });

    test('caps records and keeps the newest', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final path = '${dir.path}/ledger.jsonl';
      final l = TrajectoryLedger(path: path, maxRecords: 3);
      for (var i = 0; i < 5; i++) {
        await l.add(
          TrajectoryRecord(
            id: 'r$i',
            createdAt: DateTime.utc(2026),
            sessionId: 's',
            success: true,
          ),
        );
      }
      expect(l.length, 3);
      expect(l.records.first.id, 'r2');
      await dir.delete(recursive: true);
    });
  });

  group('SkillBanditStats', () {
    test('untried wins exploration; higher mean wins when counts are equal',
        () {
      final tried = SkillBanditStats()..observe(0.5);
      expect(tried.ucb(10, 1.414), lessThan(double.infinity));

      final good = SkillBanditStats();
      final bad = SkillBanditStats();
      for (var i = 0; i < 5; i++) {
        good.observe(0.9);
        bad.observe(0.1);
      }
      expect(good.ucb(10, 1.414), greaterThan(bad.ucb(10, 1.414)));
    });
  });

  group('SelfEvolutionEngine', () {
    test('recordTurn stores deterministic reward', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final engine = SelfEvolutionEngine(dataDir: dir.path);
      await engine.recordTurn(
        sessionId: 's1',
        success: true,
        toolNames: const ['shell', 'read_file'],
        errorCount: 1,
        task: 'deploy ke server',
      );
      expect(engine.ledger.length, 1);
      final rec = engine.ledger.records.first;
      expect(rec.sessionId, 's1');
      expect(rec.reward, closeTo(0.6 + 0.125 + 0.075, 0.001));
      await dir.delete(recursive: true);
    });

    test('judge arbitrates ambiguous record within budget', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final events = EventBus();
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        llmProvider: _StubLlm('SCORE: 0.10\nREASON: outcome was wrong'),
        events: events,
      );
      await engine.recordTurn(
        sessionId: 's1',
        success: true,
        feedback: false,
        toolNames: const ['shell'],
      );
      await engine.consolidate();
      final rec = engine.ledger.records.first;
      expect(rec.judgeScore, closeTo(0.10, 0.001));
      expect(rec.reward, closeTo(0.5 * 0.85 + 0.5 * 0.10, 0.001));
      final kinds = [for (final e in events.recent(limit: 10)) e['type']];
      expect(kinds, contains('evolution.consolidated'));
      await dir.delete(recursive: true);
    });

    test('unambiguous successful record is not judged', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        llmProvider: _StubLlm('SCORE: 0.10\nREASON: should not be used'),
      );
      await engine.recordTurn(sessionId: 's1', success: true);
      await engine.consolidate();
      expect(engine.ledger.records.first.judgeScore, isNull);
      await dir.delete(recursive: true);
    });

    test('judge budget caps LLM calls per day', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        llmProvider: _StubLlm('SCORE: 0.10\nREASON: bad'),
        config: const EvolutionConfig(maxJudgePerDay: 1),
      );
      await engine.recordTurn(sessionId: 's1', success: true, feedback: false);
      await engine.recordTurn(sessionId: 's2', success: true, feedback: false);
      await engine.consolidate();
      final judged = engine.ledger.records.where((r) => r.judgeScore != null);
      expect(judged.length, 1);
      await dir.delete(recursive: true);
    });

    test('quarantines collapsed skill and records a corrective lesson',
        () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final registry = SkillRegistry()..register(_skill('alpha'));
      final reflection = ReflectionEngine(
        storePath: '${dir.path}/lessons.json',
      );
      final events = EventBus();
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        skills: registry,
        reflectionEngine: reflection,
        events: events,
      );
      for (var i = 0; i < 6; i++) {
        await engine.recordTurn(
          sessionId: 's$i',
          success: false,
          errorCount: 1,
          toolNames: const ['shell'],
          skillSlug: 'alpha',
        );
      }
      await engine.consolidate();
      expect(registry.get('alpha')!.status, SkillStatus.draft);
      expect(reflection.length, 1);
      final kinds = [for (final e in events.recent(limit: 10)) e['type']];
      expect(kinds, contains('evolution.quarantined'));
      await dir.delete(recursive: true);
    });

    test('skips quarantine below minimum samples', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final registry = SkillRegistry()..register(_skill('beta'));
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        skills: registry,
      );
      for (var i = 0; i < 3; i++) {
        await engine.recordTurn(
          sessionId: 's$i',
          success: false,
          errorCount: 1,
          toolNames: const ['shell'],
          skillSlug: 'beta',
        );
      }
      await engine.consolidate();
      expect(registry.get('beta')!.status, SkillStatus.approved);
      await dir.delete(recursive: true);
    });

    test('respects daily quarantine cap', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final registry = SkillRegistry()
        ..register(_skill('a'))
        ..register(_skill('b'));
      final engine = SelfEvolutionEngine(
        dataDir: dir.path,
        skills: registry,
        config: const EvolutionConfig(maxQuarantinesPerDay: 1),
      );
      for (final slug in const ['a', 'b']) {
        for (var i = 0; i < 6; i++) {
          await engine.recordTurn(
            sessionId: 's$slug$i',
            success: false,
            errorCount: 1,
            toolNames: const ['shell'],
            skillSlug: slug,
          );
        }
      }
      await engine.consolidate();
      final drafts = registry.all
          .where((s) => s.status == SkillStatus.draft)
          .map((s) => s.slug)
          .toSet();
      expect(drafts.length, 1);
      await dir.delete(recursive: true);
    });

    test('selectSkill prefers the higher-reward skill', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final engine = SelfEvolutionEngine(dataDir: dir.path);
      for (var i = 0; i < 4; i++) {
        await engine.recordTurn(
          sessionId: 'g$i',
          success: true,
          skillSlug: 'good',
        );
        await engine.recordTurn(
          sessionId: 'b$i',
          success: false,
          skillSlug: 'bad',
        );
      }
      expect(engine.selectSkill(), 'good');
      await dir.delete(recursive: true);
    });

    test('start/stop is idempotent and persists state', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_evo');
      final engine = SelfEvolutionEngine(dataDir: dir.path);
      engine.start();
      engine.start();
      await engine.stop();
      await engine.stop();
      expect(File('${dir.path}/evolution/state.json').existsSync(), isTrue);
      await dir.delete(recursive: true);
    });
  });
}
