import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late TrajectoryLogger logger;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_traj_test_');
    logger = TrajectoryLogger(directory: temp.path);
  });

  tearDown(() async {
    try { await temp.delete(recursive: true); } catch (_) {}
  });

  test('export redacts secrets, caps fields and excludes sessions', () async {
    await logger.logTurn(
      sessionId: 's1',
      input: 'pakai key sk-abcdef1234567890 untuk panggil api',
      output: 'Bearer eyJhbGciOiJIUzI1NiJ9.token sudah dipakai',
      tools: ['web_fetch'],
      success: true,
    );
    await logger.logTurn(
      sessionId: 's2',
      input: 'rahasia user lain',
      output: 'ok',
      tools: const [],
      success: true,
    );

    final outPath = '${temp.path}/export/train.jsonl';
    final exported = await logger.exportForTraining(
      outputPath: outPath,
      excludeSessions: {'s2'},
    );

    expect(exported, 1);
    final lines = await File(outPath).readAsLines();
    expect(lines, hasLength(1));
    final entry = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(entry['session'], 's1');
    expect(entry['input'], isNot(contains('sk-abcdef1234567890')));
    expect(entry['input'], contains('sk-<REDACTED>'));
    expect(entry['output'], isNot(contains('eyJhbGciOiJIUzI1NiJ9.token')));
    expect(entry['output'], contains('Bearer <REDACTED>'));
  });

  test('export respects maxFieldChars', () async {
    await logger.logTurn(
      sessionId: 's1',
      input: 'x' * 5000,
      output: 'y' * 5000,
      tools: const [],
    );
    final outPath = '${temp.path}/export/capped.jsonl';
    await logger.exportForTraining(outputPath: outPath, maxFieldChars: 100);
    final entry = jsonDecode((await File(outPath).readAsLines()).single)
        as Map<String, dynamic>;
    expect((entry['input'] as String).length, lessThan(200));
  });

  test('custom redactor runs after the default pass', () async {
    await logger.logTurn(
      sessionId: 's1',
      input: 'nama saya Budi',
      output: 'halo',
      tools: const [],
    );
    final outPath = '${temp.path}/export/custom.jsonl';
    await logger.exportForTraining(
      outputPath: outPath,
      customRedactor: (line) =>
          '${line.replaceAll('Budi', '<NAMA>')}\n{"_custom": true}',
    );
    final lines = await File(outPath).readAsLines();
    expect(lines.first, isNot(contains('Budi')));
  });

  test('export on an empty directory yields zero entries', () async {
    final exported = await logger.exportForTraining(
      outputPath: '${temp.path}/none.jsonl',
    );
    expect(exported, 0);
  });
}
