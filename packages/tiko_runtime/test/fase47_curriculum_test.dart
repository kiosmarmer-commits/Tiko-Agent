import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-curr', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

void main() {
  late String dataDir;
  late String workspace;

  setUp(() async {
    dataDir = await Directory.systemTemp
        .createTemp('curriculum_test')
        .then((d) => d.path);
    workspace = dataDir;
  });

  tearDown(() async {
    await Directory(dataDir).delete(recursive: true);
  });

  SkillCurriculum newCurriculum() => SkillCurriculum(
        store: CurriculumStore(
          path: '$dataDir/curriculum.json',
        ),
      );

  test('CURR-1: plan \u2014 skill terlemah didahulukan, pass-rate 1 di-skip',
      () async {
    final curriculum = newCurriculum();
    final lessons = await curriculum.planFromPassRates({
      'caching': 0.25,
      'parsing': 0.8,
      'cli': 1.0,
    });
    expect(lessons.map((l) => l.skill).toList(), ['caching', 'parsing']);
    expect(lessons.first.level, 0);
    expect(lessons.last.level, 2);
  });

  test('CURR-2: next \u2192 lesson level terendah', () async {
    final curriculum = newCurriculum();
    await curriculum.planFromPassRates({
      'parsing': 0.6,
      'caching': 0.25,
    });
    expect(curriculum.next()!.skill, 'caching');
  });

  test('CURR-3: advance lulus menaikkan level; level 3 \u2192 done', () async {
    final curriculum = newCurriculum();
    await curriculum.planFromPassRates({'caching': 0.25});
    expect(await curriculum.advance('caching', passed: true), isTrue);
    expect(curriculum.next()!.level, 1);
    expect(await curriculum.advance('caching', passed: true), isTrue);
    expect(await curriculum.advance('caching', passed: true), isTrue);
    expect(curriculum.next(), isNull);
  });

  test('CURR-4: advance gagal \u2192 status active, level tetap', () async {
    final curriculum = newCurriculum();
    await curriculum.planFromPassRates({'caching': 0.25});
    await curriculum.advance('caching', passed: true);
    final before = curriculum.next()!.level;
    await curriculum.advance('caching', passed: false);
    final lesson = curriculum.next()!;
    expect(lesson.level, before);
    expect(lesson.status, 'active');
  });

  test('CURR-5: advance skill tak dikenal \u2192 false (fail-closed)', () async {
    final curriculum = newCurriculum();
    expect(await curriculum.advance('tidak_ada', passed: true), isFalse);
  });

  test('CURR-6: persist roundtrip \u2014 engine baru melanjutkan kurikulum',
      () async {
    final curriculum = newCurriculum();
    await curriculum.planFromPassRates({'caching': 0.25});
    await curriculum.advance('caching', passed: true);
    final resumed = newCurriculum();
    expect(resumed.next()!.skill, 'caching');
    expect(resumed.next()!.level, 1);
  });

  test('CURR-7: tool \u2014 plan dari report JSON, next, advance, list', () async {
    final tool = CurriculumTool(curriculum: newCurriculum());
    final reportJson = '{"results":['
        '{"skill":"caching","passed":false},'
        '{"skill":"caching","passed":true},'
        '{"skill":"cli","passed":true}'
        ']}';
    final planned = await tool.run(
      {'action': 'plan', 'report': reportJson},
      _ctx(workspace),
    );
    expect(planned.isError, isFalse);
    expect(planned.content, contains('"caching"'));
    final next = await tool.run({'action': 'next'}, _ctx(workspace));
    expect(next.content, contains('"caching"'));
    final advanced = await tool.run(
      {'action': 'advance', 'skill': 'caching', 'passed': true},
      _ctx(workspace),
    );
    expect(advanced.isError, isFalse);
    final list = await tool.run({'action': 'list'}, _ctx(workspace));
    expect(list.content, contains('"total_lessons"'));
  });
}
