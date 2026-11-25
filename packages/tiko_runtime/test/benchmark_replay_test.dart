import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// R4 - benchmark harness replay: trajektori (JSONL hasil TrajectoryLogger)
/// diputar ulang sebagai kasus eval di atas runtime mock, dengan overlay
/// ekspektasi dan perbandingan baseline (gerbang regresi).
void main() {
  TikoRuntime? rt;
  Directory? temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('r4-replay-');
    final config = File(p.join(temp!.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${temp!.path}/workspace
data_dir: ${temp!.path}/data
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
    rt = await TikoRuntime.create(configPath: config.path, safe: false);
  });

  tearDownAll(() async {
    await rt?.close();
    final dir = temp;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  String entry({
    required String session,
    required String input,
    required String output,
    List<String> tools = const [],
    bool success = true,
  }) =>
      jsonEncode({
        'ts': '2026-01-01T00:00:00.000Z',
        'session': session,
        'input': input,
        'output': output,
        'tools': tools,
        'latency_ms': 42,
        'success': success,
      });

  String writeTrajectories(String dirPath, List<String> lines) {
    final dir = Directory(p.join(temp!.path, dirPath))..createSync(recursive: true);
    File(p.join(dir.path, 'traj-2026-01-01.jsonl'))
        .writeAsStringSync('${lines.join('\n')}\n');
    return dir.path;
  }

  test('specsFromTrajectoryDir: sesi -> kasus, sukses terburuk menang', () async {
    final dir = writeTrajectories('traj-1', [
      entry(session: 'rollout-t1', input: 'soal 1', output: 'jawaban a'),
      entry(session: 'rollout-t1', input: 'soal 2', output: 'jawaban b', tools: ['calc']),
      entry(
        session: 'rollout-t1',
        input: 'soal 3',
        output: 'x',
        success: false,
      ),
      entry(session: 'rollout-t2', input: 'soal gagal', output: '', success: false),
    ]);

    final tasks = await specsFromTrajectoryDir(dir);
    expect(tasks, hasLength(2));
    expect(tasks[0].id, 'rollout-t1');
    expect(tasks[0].prompt, 'soal 1');
    expect(tasks[0].expectSuccess, isFalse, reason: 'ada satu entri gagal');
    expect(tasks[1].id, 'rollout-t2');
    expect(tasks[1].expectSuccess, isFalse, reason: 'entri t2 tercatat gagal');

    final withTools = await specsFromTrajectoryDir(dir, requireTools: true);
    expect(withTools[0].minToolCalls, 1);
  });

  test('baris korup dan sesi kosong di-skip (fail-soft)', () async {
    final dir = writeTrajectories('traj-2', [
      '{json rusak',
      entry(session: 'ok-1', input: 'halo', output: 'x'),
      entry(session: '', input: 'tanpa sesi', output: 'y'),
    ]);
    final tasks = await specsFromTrajectoryDir(dir);
    expect(tasks, hasLength(1));
    expect(tasks.single.id, 'ok-1');
  });

  test('overlay menimpa ekspektasi; overlay tanpa id diabaikan', () async {
    final dir = writeTrajectories('traj-3', [
      entry(session: 'rollout-a', input: 'soal a', output: ''),
    ]);
    final overlay = File(p.join(temp!.path, 'overlay.jsonl'))
      ..writeAsStringSync('''
{"id":"rollout-a","expect_contains":["detik"],"min_tool_calls":1}
garis tidak valid tidak melintas overlay tanpa id
''');
    final report = await runBenchmarkReplay(
      rt!,
      trajectoryDir: dir,
      overlayPath: overlay.path,
      channel: 'eval-replay-test',
    );
    expect(report['overlay_applied'], 1);
    expect(report['total'], 1);
  });

  test('pipeline penuh: mock pass, baseline membandingkan skor', () async {
    final dir = writeTrajectories('traj-4', [
      entry(
        session: 'bench-greeting',
        input: 'halo',
        output: 'Halo! Saya mock agent.',
      ),
    ]);
    final overlay = File(p.join(temp!.path, 'overlay-bench.jsonl'))
      ..writeAsStringSync(
        '{"id":"bench-greeting","expect_contains":["mock agent"]}\n');

    final current = await runBenchmarkReplay(
      rt!,
      trajectoryDir: dir,
      overlayPath: overlay.path,
      channel: 'eval-replay-test',
      outPath: p.join(temp!.path, 'report-current.json'),
    );
    expect(current['total'], 1);
    expect(current['gate_passed'], isTrue);

    expect(File(p.join(temp!.path, 'report-current.json')).existsSync(), isTrue);

    // Baseline: score sempurna, tapi pakai overlay penampang gagal agar
    // regresi terdeteksi.
    final baselinePath = p.join(temp!.path, 'report-baseline.json');
    final baseline = await runBenchmarkReplay(
      rt!,
      trajectoryDir: dir,
      overlayPath: overlay.path,
      channel: 'eval-replay-test',
    );
    File(baselinePath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(baseline),
    );

    // Overlay "rusak" membuat kasus gagal -> harus terdeteksi sebagai
    // regresi terhadap baseline sempurna.
    final failOverlay = File(p.join(temp!.path, 'overlay-fail.jsonl'))
      ..writeAsStringSync('{"id":"bench-greeting","expect_contains":["TIDAK ADA"]}\n');
    final regressed = await runBenchmarkReplay(
      rt!,
      trajectoryDir: dir,
      overlayPath: failOverlay.path,
      baselinePath: baselinePath,
      channel: 'eval-replay-test',
    );
    final comparison = regressed['comparison'] as Map<String, dynamic>;
    expect(comparison['regressed'], contains('bench-greeting'));
    expect(comparison['gate_passed'], isFalse);
  });

  test('overlay / baseline hilang -> ArgumentError', () async {
    final dir = writeTrajectories('traj-5', [
      entry(session: 'ok-x', input: 'halo', output: 'x'),
    ]);
    await expectLater(
      runBenchmarkReplay(rt!, trajectoryDir: dir, overlayPath: '/nonexistent/o.jsonl'),
      throwsArgumentError,
    );
    await expectLater(
      runBenchmarkReplay(rt!, trajectoryDir: dir, baselinePath: '/nonexistent/b.json'),
      throwsArgumentError,
    );
  });
}
