import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko/batch_cli.dart';
import 'package:test/test.dart';

void main() {
  group('parseBatchTasksJsonl', () {
    test('parse valid jsonl dengan id eksplisit dan otomatis', () {
      final specs = parseBatchTasksJsonl('''
{"id": "kasus-1", "prompt": "ringkas berita"}

{"prompt": "siapa kamu"}
{"id": "kasus-2", "prompt": "apa itu cron"}
''');
      expect(specs, hasLength(3));
      expect(specs[0].id, 'kasus-1');
      expect(specs[1].id, 't-1');
      expect(specs[1].prompt, 'siapa kamu');
      expect(specs[2].id, 'kasus-2');
    });

    test('prompt kosong/hilang → error dengan nomor baris', () {
      expect(
        () => parseBatchTasksJsonl('{"id": "x"}'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('"prompt" wajib'),
        )),
      );
      expect(
        () => parseBatchTasksJsonl('{"prompt": "  "}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('json invalid → error dengan nomor baris', () {
      expect(
        () => parseBatchTasksJsonl('{"prompt": "ok"}\n{broken'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('baris 2'),
        )),
      );
    });

    test('baris bukan object → error', () {
      expect(
        () => parseBatchTasksJsonl('["prompt"]'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('JSON object'),
        )),
      );
    });

    test('file kosong → error', () {
      expect(
        () => parseBatchTasksJsonl('\n\n'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('kosong'),
        )),
      );
    });

    test('id terlalu panjang → error', () {
      expect(
        () => parseBatchTasksJsonl(
            '{"id": "${'x' * 129}", "prompt": "p"}'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('128'),
        )),
      );
    });
  });

  group('optValue/hasFlag', () {
    test('opsi dan flag terbaca', () {
      final args = ['--label', 'x', '--sharegpt', '--out', 'y'];
      expect(optValue(args, '--label'), 'x');
      expect(optValue(args, '--out'), 'y');
      expect(optValue(args, '--nope'), isNull);
      expect(hasFlag(args, '--sharegpt'), isTrue);
      expect(hasFlag(args, '--no-redact'), isFalse);
    });

    test('nilai di ujung hilang → null', () {
      expect(optValue(['--label'], '--label'), isNull);
    });
  });

  group('runBatch', () {
    test('eksekusi paralel tercatat di trajektori, urutan deterministik, token teragregasi', () async {
      final tmp = await Directory.systemTemp.createTemp('tiko-batch');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final logger = TrajectoryLogger(
        directory: '${tmp.path}/trajectories',
      );
      final specs = [
        for (var i = 1; i <= 4; i++)
          BatchTaskSpec(id: 't-$i', prompt: 'prompt $i'),
      ];
      final outcome = await runBatch(
        specs: specs,
        label: 'uji',
        concurrency: 2,
        logger: logger,
        executor: (spec, sessionId) async {
          expect(sessionId, 'batch:uji-${spec.id}');
          return (
            output: 'jawaban ${spec.id}',
            tools: <String>['calc'],
            success: spec.id != 't-3',
            latencyMs: 10,
            tokensUsed: 7,
          );
        },
      );
      expect(outcome.results.map((r) => r.taskId).toList(),
          ['t-1', 't-2', 't-3', 't-4']);
      expect(outcome.results.every((r) => r.success || r.taskId == 't-3'),
          isTrue);
      expect(outcome.totalTokens, 28);
      final files = Directory('${tmp.path}/trajectories')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      final lines =
          const LineSplitter().convert(files.first.readAsStringSync());
      expect(lines, hasLength(4));
      final entries = [
        for (final l in lines) jsonDecode(l) as Map<String, dynamic>,
      ];
      final sessions = entries.map((e) => e['session']).toSet();
      expect(
        sessions.containsAll(<String>{
          'batch:uji-t-1',
          'batch:uji-t-2',
          'batch:uji-t-3',
          'batch:uji-t-4',
        }),
        isTrue,
      );
    });
  });

  group('buildBatchReport', () {
    test('agregasi success/failed, latency, dan token', () {
      final report = buildBatchReport(
        label: 'uji',
        concurrency: 2,
        outcome: const BatchOutcome(
          results: [
            RolloutResult(
              taskId: 't-1',
              sessionId: 'batch:uji-t-1',
              output: 'a',
              tools: ['calc'],
              success: true,
              latencyMs: 100,
              reward: 1,
            ),
            RolloutResult(
              taskId: 't-2',
              sessionId: 'batch:uji-t-2',
              output: 'b',
              tools: [],
              success: false,
              latencyMs: 300,
              reward: 0,
            ),
            RolloutResult(
              taskId: 't-3',
              sessionId: 'batch:uji-t-3',
              output: 'c',
              tools: [],
              success: true,
              latencyMs: 200,
              reward: 1,
            ),
          ],
          totalTokens: 42,
        ),
      );
      expect(report['label'], 'uji');
      expect(report['concurrency'], 2);
      expect(report['total'], 3);
      expect(report['success'], 2);
      expect(report['failed'], 1);
      expect(report['total_tokens'], 42);
      expect(report['avg_latency_ms'], '200.0');
      expect(report['max_latency_ms'], 300);
      expect((report['results'] as List), hasLength(3));
    });
  });

  test('batchArtifactPath: karakter label dinormalisasi + direktori batch', () {
    final path = batchArtifactPath(dataDir: 'data', label: 'label aneh 1');
    expect(path.contains('data${Platform.pathSeparator}batch'), isTrue);
    expect(path.endsWith('-label_aneh_1.json'), isTrue);
  });
}
