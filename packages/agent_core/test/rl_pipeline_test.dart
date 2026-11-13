import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late TrajectoryLogger logger;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rl-pipeline-test');
    logger = TrajectoryLogger(directory: '${tempDir.path}/trajectories');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('BatchRolloutRunner', () {
    test('runs all tasks, logs turns, keeps deterministic order', () async {
      final runner = BatchRolloutRunner(
        logger: logger,
        concurrency: 3,
        executor: (task) async => (
          output: 'jawaban ${task.id}',
          tools: ['calc'],
          success: task.id != 't-fail',
          latencyMs: 11,
        ),
      );
      final results = await runner.run([
        const RolloutTask(id: 't1', prompt: 'soal satu'),
        const RolloutTask(id: 't2', prompt: 'soal dua'),
        const RolloutTask(id: 't-fail', prompt: 'soal gagal'),
        const RolloutTask(id: 't3', prompt: 'soal tiga'),
      ]);
      expect(results.map((r) => r.taskId).toList(),
          ['t1', 't2', 't-fail', 't3']);
      expect(results.map((r) => r.reward).toList(), [1.0, 1.0, 0.0, 1.0]);
      expect(results[2].success, isFalse);

      final files = tempDir
          .listSync()
          .whereType<Directory>()
          .expand((d) => d.listSync().whereType<File>())
          .toList();
      expect(files, isNotEmpty);
      final content = await File(files.first.path).readAsString();
      final lines = content.trim().split('\n');
      expect(lines, hasLength(4));
      final first = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(first['session'], 'rollout-t1');
      expect(first['input'], 'soal satu');
      expect(first['success'], isTrue);
    });

    test('executor exception becomes a failed rollout, not a crash', () async {
      final runner = BatchRolloutRunner(
        logger: logger,
        executor: (task) async => throw StateError('boom'),
      );
      final results = await runner.run([
        const RolloutTask(id: 'x', prompt: 'p'),
      ]);
      expect(results.single.success, isFalse);
      expect(results.single.reward, 0.0);
      expect(results.single.output, contains('boom'));
    });

    test('custom reward function is applied', () async {
      final runner = BatchRolloutRunner(
        logger: logger,
        executor: (task) async => (
          output: 'ok',
          tools: ['calc'],
          success: true,
          latencyMs: 5,
        ),
        rewardFn: (r) => r.success ? 1.0 - r.tools.length * 0.1 : 0.0,
      );
      final results = await runner.run([
        const RolloutTask(id: 'a', prompt: 'p'),
      ]);
      expect(results.single.reward, closeTo(0.9, 1e-9));
    });
  });

  group('exportShareGpt', () {
    test('groups turns by session in timestamp order with privacy guard',
        () async {
      await logger.logTurn(
        sessionId: 's1',
        input: 'kunci sk-abc123def456ghi789',
        output: 'jawaban s1a',
        tools: ['calc'],
      );
      await logger.logTurn(
        sessionId: 's2',
        input: 'pertanyaan s2',
        output: 'jawaban s2',
        tools: const [],
        success: false,
      );
      await logger.logTurn(
        sessionId: 's1',
        input: 'lanjutan s1',
        output: 'jawaban s1b',
        tools: ['calc', 'shell'],
      );
      final outPath = '${tempDir.path}/sharegpt.jsonl';
      final count = await logger.exportShareGpt(
        outputPath: outPath,
        excludeSessions: {'s2'},
      );
      expect(count, 1);
      final row =
          jsonDecode(await File(outPath).readAsString()) as Map<String, dynamic>;
      final convo = (row['conversations'] as List).cast<Map>();
      expect(convo.map((t) => t['from']).toList(), ['human', 'gpt', 'human', 'gpt']);
      expect(convo.first['value'], contains('<REDACTED>'));
      expect(convo.first['value'], isNot(contains('sk-abc123')));
      expect(row['tools'], ['calc', 'shell']);
      expect(row['success'], isTrue);
    });

    test('empty directory exports zero conversations', () async {
      final count = await logger.exportShareGpt(
        outputPath: '${tempDir.path}/none.jsonl',
      );
      expect(count, 0);
    });
  });

  group('TrajectoryCompressor', () {
    test('caps turn values and drops empty conversations', () async {
      final input = File('${tempDir.path}/in.jsonl');
      final longTurn = 'x' * 5000;
      final validRow = {
        'conversations': [
          {'from': 'human', 'value': longTurn},
          {'from': 'gpt', 'value': 'ok'},
        ],
        'tools': ['a'],
        'success': true,
      };
      await input.writeAsString(
        '${jsonEncode(validRow)}\n'
        '${jsonEncode({'conversations': <Map<String, String>>[]})}\n'
        'bukan-json\n',
      );
      final outPath = '${tempDir.path}/out.jsonl';
      final written = await TrajectoryCompressor.compress(
        input.path,
        outPath,
        maxCharsPerTurn: 100,
      );
      expect(written, 1);
      final row =
          jsonDecode(await File(outPath).readAsString()) as Map<String, dynamic>;
      final convo = (row['conversations'] as List).cast<Map>();
      expect((convo.first['value'] as String).length, lessThanOrEqualTo(101));
      expect(convo.last['value'], 'ok');
    });

    test('missing input file yields zero rows', () async {
      final written = await TrajectoryCompressor.compress(
        '${tempDir.path}/missing.jsonl',
        '${tempDir.path}/out.jsonl',
      );
      expect(written, 0);
    });
  });

  test('end-to-end: batch rollout → ShareGPT export → compression',
      () async {
    final runner = BatchRolloutRunner(
      logger: logger,
      executor: (task) async => (
        output: 'selesai ${task.id}',
        tools: const <String>[],
        success: true,
        latencyMs: 3,
      ),
    );
    await runner.run([
      const RolloutTask(id: 'e1', prompt: 'tugas e1'),
      const RolloutTask(id: 'e2', prompt: 'tugas e2'),
    ]);
    final sharegptPath = '${tempDir.path}/sg.jsonl';
    final conversations = await logger.exportShareGpt(
      outputPath: sharegptPath,
    );
    expect(conversations, 2);
    final compressedPath = '${tempDir.path}/sg-small.jsonl';
    final rows = await TrajectoryCompressor.compress(
      sharegptPath,
      compressedPath,
    );
    expect(rows, 2);
    final lines = (await File(compressedPath).readAsString())
        .trim()
        .split('\n');
    expect(lines, hasLength(2));
    final row = jsonDecode(lines.first) as Map<String, dynamic>;
    final convo = (row['conversations'] as List).cast<Map>();
    expect(convo.first['value'], 'tugas e1');
  });
}
