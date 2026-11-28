import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx(String workspace) => ToolContext(
      session: Session(id: 's-swe', channel: 'test', userKey: 'u'),
      workspacePath: workspace,
    );

void main() {
  late String workspace;

  setUp(() async {
    workspace = await Directory.systemTemp
        .createTemp('swe_test')
        .then((d) => d.path);
    await Directory('$workspace/lib').create(recursive: true);
    await File('$workspace/lib/parser_config.dart').writeAsString(
      'int parseRetry(String raw) => 0; // retry timeout parser\n',
    );
    await File('$workspace/lib/other.dart').writeAsString('void other() {}\n');
  });

  tearDown(() async {
    await Directory(workspace).delete(recursive: true);
  });

  test('SWE-1: localizer \u2014 kandidat file diranking berdasar token issue',
      () async {
    const localizer = SweLocalizer();
    final candidates = await localizer.localize(
      issue: 'parseRetry timeout selalu nol ketika parser config retry kosong',
      workspaceRoot: workspace,
    );
    expect(candidates, isNotEmpty);
    expect(candidates.first.path, contains('parser_config.dart'));
    expect(candidates.first.score, greaterThan(0));
    expect(candidates.first.snippet, isNotEmpty);
  });

  test('SWE-2: pipeline \u2014 verifikasi lulus iterasi pertama', () async {
    final prompts = <String>[];
    final pipeline = SwePipeline(
      runTurn: (prompt) async {
        prompts.add(prompt);
        return 'selesai';
      },
      verify: (cmd) async => const SweVerifyResult(ok: true, exitCode: 0, output: ''),
    );
    final report = await pipeline.run(
      issue: 'parseRetry timeout',
      verifyCommand: 'dart test',
      workspaceRoot: workspace,
    );
    expect(report.ok, isTrue);
    expect(report.iterations, 1);
    expect(prompts, hasLength(1));
    expect(prompts.single, contains('parseRetry'));
  });

  test('SWE-3: pipeline \u2014 umpan balik kegagalan diteruskan ke iterasi berikut',
      () async {
    var turnCount = 0;
    final pipeline = SwePipeline(
      runTurn: (prompt) async {
        turnCount++;
        return 'turn $turnCount';
      },
      verify: (cmd) async => turnCount < 2
          ? const SweVerifyResult(
              ok: false, exitCode: 1, output: 'Expected: 3\nActual: 0')
          : const SweVerifyResult(ok: true, exitCode: 0, output: ''),
    );
    final report = await pipeline.run(
      issue: 'parseRetry timeout',
      verifyCommand: 'dart test',
      workspaceRoot: workspace,
    );
    expect(report.ok, isTrue);
    expect(report.iterations, 2);
    expect(report.verifyRuns.map((v) => v.ok).toList(), [false, true]);
  });

  test('SWE-4: pipeline \u2014 iterasi habis \u2192 ok false dengan ringkasan jujur',
      () async {
    final pipeline = SwePipeline(
      maxIterations: 2,
      runTurn: (prompt) async => 'selesai',
      verify: (cmd) async =>
          const SweVerifyResult(ok: false, exitCode: 1, output: 'gagal'),
    );
    final report = await pipeline.run(
      issue: 'parseRetry timeout',
      verifyCommand: 'dart test',
      workspaceRoot: workspace,
    );
    expect(report.ok, isFalse);
    expect(report.iterations, 2);
    expect(report.summary, contains('belum lulus'));
  });

  test('SWE-5: never-raises \u2014 turn error/verify error \u2192 laporan terstruktur',
      () async {
    final pipelineFailTurn = SwePipeline(
      runTurn: (prompt) async => throw StateError('llm mati'),
      verify: (cmd) async => const SweVerifyResult(ok: true, exitCode: 0, output: ''),
    );
    final r1 = await pipelineFailTurn.run(
      issue: 'x',
      verifyCommand: 'true',
      workspaceRoot: workspace,
    );
    expect(r1.ok, isFalse);
    expect(r1.summary, contains('turn agent gagal'));

    final pipelineFailVerify = SwePipeline(
      runTurn: (prompt) async => 'selesai',
      verify: (cmd) async => throw StateError('verify mati'),
    );
    final r2 = await pipelineFailVerify.run(
      issue: 'x',
      verifyCommand: 'true',
      workspaceRoot: workspace,
    );
    expect(r2.ok, isFalse);
    expect(r2.summary, contains('verifikasi gagal'));
  });

  test('SWE-6: tool swe_fix \u2014 argumen wajib + report JSON', () async {
    final pipeline = SwePipeline(
      runTurn: (prompt) async => 'selesai',
      verify: (cmd) async => const SweVerifyResult(ok: true, exitCode: 0, output: ''),
    );
    final tool = SweFixTool(pipeline: pipeline);
    final missing = await tool.run({'issue': 'x'}, _ctx(workspace));
    expect(missing.isError, isTrue);
    final ok = await tool.run(
      {'issue': 'parseRetry timeout', 'verify': 'dart test'},
      _ctx(workspace),
    );
    expect(ok.isError, isFalse);
    expect(ok.content, contains('"ok": true'));
    expect(ok.content, contains('parser_config.dart'));
  });
}
