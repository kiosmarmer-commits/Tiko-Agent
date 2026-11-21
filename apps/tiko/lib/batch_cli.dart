import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// P5 Hermes-parity: batch processing CLI (tiko batch run/export).
/// Logika parsing & agregasi dipisah dari bin/tiko.dart agar mudah diuji.

const int maxBatchTasks = 10000;
const int maxConcurrency = 16;

/// Satu task hasil parse file JSONL `--tasks`.
class BatchTaskSpec {
  const BatchTaskSpec({required this.id, required this.prompt});

  final String id;
  final String prompt;
}

/// Parse isi file JSONL batch: satu task per baris berbentuk
/// `{"id": "opsional", "prompt": "wajib non-kosong"}`. Baris kosong
/// dilewati; baris invalid gagal dengan nomor baris (fail-closed).
List<BatchTaskSpec> parseBatchTasksJsonl(String source) {
  final tasks = <BatchTaskSpec>[];
  final lines = const LineSplitter().convert(source);
  var autoId = 0;
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty) continue;
    final lineNo = i + 1;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw FormatException('baris $lineNo: JSON tidak valid ($e)');
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('baris $lineNo: harus JSON object');
    }
    final id = (decoded['id'] as String?)?.trim() ?? '';
    final prompt = (decoded['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      throw FormatException('baris $lineNo: "prompt" wajib string non-kosong');
    }
    if (id.isEmpty) {
      autoId++;
      tasks.add(BatchTaskSpec(id: 't-$autoId', prompt: prompt));
    } else {
      if (id.length > 128) {
        throw FormatException('baris $lineNo: "id" maksimal 128 karakter');
      }
      tasks.add(BatchTaskSpec(id: id, prompt: prompt));
    }
  }
  if (tasks.isEmpty) {
    throw const FormatException('file tasks kosong');
  }
  if (tasks.length > maxBatchTasks) {
    throw const FormatException(
        'maksimum $maxBatchTasks task per batch');
  }
  return tasks;
}

/// Baca nilai opsi `--nama NILAI` (kemunculan pertama).
String? optValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

/// Cek opsi boolean `--nama`.
bool hasFlag(List<String> args, String name) => args.contains(name);

/// Executor satu task batch; wired ke `rt.chatWithStatus` oleh host.
typedef BatchExecutor = Future<({String output, List<String> tools, bool success, int? latencyMs, int tokensUsed})>
    Function(BatchTaskSpec spec, String sessionId);

/// Hasil satu batch run: hasil rollout urut + total token aktual.
class BatchOutcome {
  const BatchOutcome({required this.results, required this.totalTokens});

  final List<RolloutResult> results;
  final int totalTokens;
}

/// Jalankan batch rollouts lewat [executor] dan log tiap turn ke [logger]
/// (dataDir/trajectories). Urutan hasil deterministik mengikuti urutan task
/// meski eksekusi paralel (BatchRolloutRunner).
Future<BatchOutcome> runBatch({
  required List<BatchTaskSpec> specs,
  required String label,
  required int concurrency,
  required TrajectoryLogger logger,
  required BatchExecutor executor,
}) async {
  final prefix = 'batch:$label';
  final tokensById = <String, int>{};
  final runner = BatchRolloutRunner(
    logger: logger,
    concurrency: concurrency,
    sessionPrefix: prefix,
    executor: (task) async {
      final spec = BatchTaskSpec(id: task.id, prompt: task.prompt);
      final outcome =
          await executor(spec, '$prefix-${task.id}');
      tokensById[task.id] = outcome.tokensUsed;
      return (
        output: outcome.output,
        tools: outcome.tools,
        success: outcome.success,
        latencyMs: outcome.latencyMs,
      );
    },
  );
  final results = await runner.run([
    for (final s in specs) RolloutTask(id: s.id, prompt: s.prompt),
  ]);
  return BatchOutcome(
    results: results,
    totalTokens: tokensById.values.fold(0, (a, b) => a + b),
  );
}

/// Agregasi hasil batch rollouts menjadi laporan JSON.
Map<String, dynamic> buildBatchReport({
  required String label,
  required int concurrency,
  required BatchOutcome outcome,
}) {
  final results = outcome.results;
  final successCount = results.where((r) => r.success).length;
  final latencies = results.map((r) => r.latencyMs ?? 0).toList()..sort();
  return {
    'label': label,
    'concurrency': concurrency,
    'total': results.length,
    'success': successCount,
    'failed': results.length - successCount,
    'total_tokens': outcome.totalTokens,
    'avg_latency_ms': latencies.isEmpty
        ? 0
        : (latencies.reduce((a, b) => a + b) / latencies.length)
            .toStringAsFixed(1),
    'max_latency_ms': latencies.isEmpty ? 0 : latencies.last,
    'results': [for (final r in results) r.toJson()],
  };
}

/// Lokasi artefak laporan batch, selaras pola `eval`.
String batchArtifactPath({
  required String dataDir,
  required String label,
}) {
  final safeLabel = label.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return p.join(
    p.join(dataDir, 'batch'),
    '${DateTime.now().toUtc().millisecondsSinceEpoch}-$safeLabel.json',
  );
}
