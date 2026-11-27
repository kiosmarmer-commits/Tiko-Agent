import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  group('SkillBenchmark harness', () {
    const harness = SkillBenchmark();

    SkillBenchmarkRunner okRunner(List<String> tools) => (c, _) async =>
        SkillBenchmarkTurn(
          text: 'hasil ${c.prompt}',
          success: true,
          tokensUsed: 12,
          latencyMs: 3,
          toolNames: tools,
        );

    test('EVAL02-1: penilaian contains + tools + pass/fail', () async {
      final report = await harness.run(
        [
          const SkillBenchmarkCase(
            id: 'c1',
            slug: 'halo',
            prompt: 'sapa',
            expectedContains: ['hasil'],
            expectedTools: {'shell'},
          ),
          const SkillBenchmarkCase(
            id: 'c2',
            slug: 'halo',
            prompt: 'lapor',
            expectedContains: ['tidak-ada'],
          ),
        ],
        okRunner(['shell']),
      );
      expect(report.totalCases, 2);
      expect(report.passedCases, 1);
      expect(report.overallPassRate, closeTo(0.5, 1e-9));
      expect(report.passRateBySkill['halo'], closeTo(0.5, 1e-9));
      expect(report.results.first.passed, isTrue);
      expect(report.results.last.failureReason, contains('tidak-ada'));
    });

    test('EVAL02-2: runner error → kasus gagal, bukan exception', () async {
      final report = await harness.run(
        [const SkillBenchmarkCase(id: 'boom', slug: 'x', prompt: 'p')],
        (c, _) async => throw StateError('meledak'),
      );
      expect(report.results.single.passed, isFalse);
      expect(report.results.single.failureReason, contains('meledak'));
    });

    test('EVAL02-3: regresi vs run sebelumnya terdeteksi', () async {
      final before = await harness.run(
        [
          const SkillBenchmarkCase(id: 'a', slug: 's', prompt: '1'),
          const SkillBenchmarkCase(id: 'b', slug: 's', prompt: '2'),
        ],
        (c, _) async => const SkillBenchmarkTurn(
          text: 'ok', success: true,
        ),
      );
      final after = await harness.run(
        [
          const SkillBenchmarkCase(id: 'a', slug: 's', prompt: '1'),
          const SkillBenchmarkCase(id: 'b', slug: 's', prompt: '2'),
        ],
        (c, _) async => SkillBenchmarkTurn(
          text: 'ok',
          success: c.id == 'b',
        ),
      );
      expect(after.regressionsVs(before), ['s']);
    });

    test('EVAL02-4: loadCases JSON array dan JSONL; save/load report',
        () async {
      final temp = await Directory.systemTemp.createTemp('tiko_eval02_');
      addTearDown(() => temp.delete(recursive: true));
      final asArray = await harness.run(
        harness.loadCases(
          '[{"id":"j1","skill":"s","prompt":"p","expected_contains":["ok"]}]',
        ),
        (c, _) async => const SkillBenchmarkTurn(text: 'ok', success: true),
      );
      expect(asArray.passedCases, 1);

      final asJsonl = harness.loadCases(
        '{"id":"j2","skill":"s","prompt":"p"}\n{"id":"j3","skill":"t","prompt":"q"}\n',
      );
      expect(asJsonl, hasLength(2));

      final path = p.join(temp.path, 'bench', 'report.json');
      expect(harness.saveReport(asArray, path), isTrue);
      final loaded = harness.loadReport(path);
      expect(loaded, isNotNull);
      expect(loaded!.results.single.caseId, 'j1');
      expect(harness.loadReport(p.join(temp.path, 'absen.json')), isNull);
    });
  });

  test('EVAL02-5: tool skill_benchmark — inline cases + persist + validasi',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_eval02_tool_');
    addTearDown(() => temp.delete(recursive: true));
    final reportPath = p.join(temp.path, 'benchmarks', 'skill_benchmark.json');
    var calls = 0;
    final tool = SkillBenchmarkTool(
      runner: (cases, previous) async {
        calls++;
        expect(previous, isNull);
        final harness = const SkillBenchmark();
        return harness.run(
          cases,
          (c, _) async =>
              SkillBenchmarkTurn(text: 'ok', success: true, toolNames: const []),
        );
      },
      defaultCasesPath: p.join(temp.path, 'skill_cases.json'),
      reportPath: reportPath,
    );
    final ctx = ToolContext(
      session: Session(id: 's', channel: 'test', userKey: 't'),
      workspacePath: temp.path,
    );

    final missing = await tool.run({}, ctx);
    expect(missing.isError, isTrue, reason: 'tanpa kasus → error jujur');

    final ok = await tool.run({
      'cases': [
        {'id': 'k1', 'skill': 'halo', 'prompt': 'sapa'},
      ],
    }, ctx);
    expect(ok.isError, isFalse);
    expect(ok.content, contains('"overall_pass_rate"'));
    expect(calls, 1);
    expect(File(reportPath).existsSync(), isTrue);
  });

  test('EVAL02-6: runtime runSkillBenchmark menjalankan turn nyata',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_eval02_rt_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'config')).create();
    final configPath = p.join(configDir.path, 'agent.yaml');
    await File(configPath).writeAsString('''
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
mcp:
  servers: []
''');
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.registry.get('skill_benchmark'), isNotNull);

    final report = await rt.runSkillBenchmark([
      const SkillBenchmarkCase(id: 'r1', slug: 'halo', prompt: 'Halo dunia'),
    ]);
    expect(report.totalCases, 1);
    expect(report.results.single.passed, isTrue);
    expect(report.results.single.tokensUsed, greaterThanOrEqualTo(0));
  });
}
