import 'dart:convert';
import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory base;

  Map<String, dynamic> entry(
    String session,
    String input,
    String output, {
    bool success = true,
    List<String> tools = const [],
  }) =>
      {
        'session': session,
        'input': input,
        'output': output,
        'tools': tools,
        'latency_ms': 10,
        'success': success,
      };

  setUp(() {
    base = Directory.systemTemp.createTempSync('tiko_harvest_');
  });

  tearDown(() {
    base.deleteSync(recursive: true);
  });

  test('panen hanya sesi sukses, dedupe prompt, tulis JSONL valid',
      () async {
    final dir = Directory('${base.path}/trajectories')..createSync();
    File('${dir.path}/traj-2026-11-25.jsonl').writeAsStringSync([
      jsonEncode(entry('s1', 'ringkas berita hari ini', 'ringkasan ok',
          tools: ['web_search'])),
      jsonEncode(entry('s2', 'hitung 5+1', '6')),
      jsonEncode(entry('s3', 'hitung 5+1', 'duplikat dedupe')),
      jsonEncode(entry('s4', '/internal command', 'perintah internal')),
      jsonEncode(entry('s5', 'deploy gagal', 'gagal', success: false)),
    ].join('\n'));

    final out = '${base.path}/golden.jsonl';
    final report = await harvestGoldenEvals(
      trajectoryDir: dir.path,
      outPath: out,
    );
    expect(report['harvested'], 2);
    expect(report['duplicates'], 1);
    expect(report['skipped_failed'], 1);
    expect(report['skipped_internal'], 1);
    expect(report['wrote_file'], isTrue);

    final lines = File(out)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(lines.length, 2);
    for (final line in lines) {
      final m = jsonDecode(line) as Map<String, dynamic>;
      expect(m['expect_success'], true);
      expect(EvalTaskSpec.fromJson(m).prompt, isNotEmpty);
    }
  });

  test('file output yang sudah ada ditolak (anti-timpa)', () async {
    final dir = Directory('${base.path}/trajectories')..createSync();
    File('${dir.path}/traj.jsonl').writeAsStringSync(
        "${jsonEncode(entry('s1', 'cari berita', 'ok'))}\n");
    final out = File('${base.path}/golden.jsonl')
      ..writeAsStringSync('existing\n');
    expect(
      () => harvestGoldenEvals(trajectoryDir: dir.path, outPath: out.path),
      throwsArgumentError,
    );
  });

  test('limit membatasi hasil; requireTools meneruskan minToolCalls',
      () async {
    final dir = Directory('${base.path}/trajectories')..createSync();
    File('${dir.path}/traj.jsonl').writeAsStringSync([
      jsonEncode(entry('a', 'tugas a', 'ok', tools: ['grep', 'read_file'])),
      jsonEncode(entry('b', 'tugas b', 'ok')),
    ].join('\n'));
    final out = '${base.path}/golden.jsonl';
    final report = await harvestGoldenEvals(
      trajectoryDir: dir.path,
      outPath: out,
      requireTools: true,
      limit: 1,
    );
    expect(report['harvested'], 1);
    final line = jsonDecode(File(out).readAsLinesSync().first)
        as Map<String, dynamic>;
    expect(line['min_tool_calls'], 2);
  });

  test('trajektori tanpa sukses: file tidak ditulis, report jujur',
      () async {
    final dir = Directory('${base.path}/trajectories')..createSync();
    File('${dir.path}/traj.jsonl')
        .writeAsStringSync("${jsonEncode(entry('x', 'gagal', 'no', success: false))}\n");
    final out = '${base.path}/golden.jsonl';
    final report = await harvestGoldenEvals(
      trajectoryDir: dir.path,
      outPath: out,
    );
    expect(report['harvested'], 0);
    expect(File(out).existsSync(), isFalse);
  });
}
