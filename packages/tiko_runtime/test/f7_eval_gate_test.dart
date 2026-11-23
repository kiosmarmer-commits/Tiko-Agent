import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// Fase F7.1 (docs/15 §8) — eval gate: dataset emas deterministik dijalankan
/// di atas runtime + provider `mock` (offline, 100% gratis). Mode live
/// (fallback provider LLM asli) aktif bila `TIKO_EVAL_LIVE=1` dan
/// `TIKO_EVAL_LIVE_CONFIG` menunjuk config provider sungguhan.
void main() {
  final live =
      Platform.environment['TIKO_EVAL_LIVE'] == '1';
  final liveConfig = Platform.environment['TIKO_EVAL_LIVE_CONFIG'] ?? '';

  /// Resolusi path fixture: CI menjalankan `dart test <dir>/test` dari
  /// workspace root, lokal dari package root — coba keduanya.
  String fixturePath(String name) {
    final candidates = [
      'packages/tiko_runtime/test/fixtures/$name',
      'test/fixtures/$name',
      p.join(_repoRoot(), 'packages', 'tiko_runtime', 'test', 'fixtures', name),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    fail('fixture eval tidak ditemukan: $name');
  }

  String readFixture(String name) =>
      File(fixturePath(name)).readAsStringSync();

  TikoRuntime? rt;
  Directory? temp;

  setUpAll(() async {
    if (live) {
      if (liveConfig.isEmpty || !File(liveConfig).existsSync()) {
        fail(
            'TIKO_EVAL_LIVE_CONFIG tidak diset / file tidak ada: "$liveConfig"');
      }
      rt = await TikoRuntime.create(configPath: liveConfig, safe: false);
      return;
    }
    temp = await Directory.systemTemp.createTemp('f7-eval-');
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
mcp:
  servers: []
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

  group('parse task eval', () {
    test('JSONL valid -> spesifikasi lengkap + default', () {
      final tasks = parseEvalTasksJsonl('''
{"id":"a","prompt":"halo","expect_contains":["x"],"min_tool_calls":2}

{"prompt":"apa saja","expect_success":false}
''');
      expect(tasks, hasLength(2));
      expect(tasks[0].id, 'a');
      expect(tasks[0].expectSuccess, isTrue);
      expect(tasks[0].expectContains, ['x']);
      expect(tasks[0].minToolCalls, 2);
      expect(tasks[1].id, 'task-3');
      expect(tasks[1].expectSuccess, isFalse);
      expect(tasks[1].minToolCalls, 0);
    });

    test('prompt kosong / JSON rusak -> FormatException bernomor baris',
        () {
      expect(() => parseEvalTasksJsonl('{"id":"x"}'),
          throwsFormatException);
      expect(
        () => parseEvalTasksJsonl('{korup'),
        throwsA(isA<FormatException>()
            .having((e) => '$e', 'pesan', contains('baris 1'))),
      );
    });
  });

  group('offline eval gate (mock deterministik)', () {
    test('parse fixture emas', () {
      final tasks = parseEvalTasksJsonl(readFixture('eval_golden.jsonl'));
      expect(tasks.length, greaterThanOrEqualTo(6));
      expect(tasks.map((t) => t.id), everyElement(isNotEmpty));
    });

    test('skor 100% di atas dataset emas (gerbang lolos)', () async {
      final tasks = parseEvalTasksJsonl(readFixture('eval_golden.jsonl'));
      final report = await runEvalGate(rt!, tasks);
      expect(report['gate_passed'], isTrue,
          reason: 'entri gagal: ${[for (final e in report['entries'] as List) e]}');
      expect(report['score'], 100.0);
      expect(report['failed'], 0);
      final toolTask = (report['entries'] as List)
          .whereType<Map<String, dynamic>>()
          .firstWhere((e) => e['task_id'] == 'kalkulator_tool');
      expect(toolTask['tool_calls'] as int, greaterThanOrEqualTo(1));
    });

    test('task gagal tercatat dengan alasan + menurunkan skor', () async {
      final tasks = [
        ...parseEvalTasksJsonl(readFixture('eval_golden.jsonl')),
        const EvalTaskSpec(
          id: 'dibuat_gagal',
          prompt: 'Halo',
          expectContains: ['MARINER_SANGAT_SULIT_DITEMUKAN'],
        ),
      ];
      final report = await runEvalGate(rt!, tasks);
      expect(report['gate_passed'], isFalse);
      expect(report['failed'], 1);
      expect(report['score'], closeTo(7.0 / 8.0 * 100.0, 0.01));
      final failed = (report['entries'] as List)
          .whereType<Map<String, dynamic>>()
          .firstWhere((e) => e['task_id'] == 'dibuat_gagal');
      expect(failed['reasons'], isNotEmpty);
    });

    test('setiap task pakai session sendiri (isolasi, urutan tetap)',
        () async {
      final tasks = parseEvalTasksJsonl(
          '{"id":"satu","prompt":"Halo"}\n{"id":"dua","prompt":"Halo"}');
      final first = await runEvalGate(rt!, tasks);
      final second = await runEvalGate(rt!, tasks);
      // Determinisme: laporan dua run identik (tanpa isian waktu).
      Map<String, dynamic> strip(Map<String, dynamic> r) => {
            for (final e in r['entries'] as List) e['task_id']: e['passed'],
          };
      expect(strip(first), equals(strip(second)));
    });
  }, skip: live);

  group('live eval fallback (provider LLM asli)', () {
    test(' semua task sukses di atas provider sungguhan', () async {
      final tasks = parseEvalTasksJsonl(readFixture('eval_live.jsonl'));
      final report = await runEvalGate(rt!, tasks);
      expect(report['gate_passed'], isTrue,
          reason: 'entri gagal: ${[for (final e in report['entries'] as List) e]}');
      expect(report['score'], 100.0);
    });
  }, skip: !live);
}

/// Naftari port lewat cwd: cari root repo untuk fallback lookup fixture.
String _repoRoot() {
  var dir = Directory.current.path;
  for (var i = 0; i < 6; i++) {
    if (Directory(p.join(dir, '.github')).existsSync()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return Directory.current.path;
}
