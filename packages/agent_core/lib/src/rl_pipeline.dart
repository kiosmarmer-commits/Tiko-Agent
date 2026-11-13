import 'dart:convert';
import 'dart:io';

import 'trajectory.dart';

/// One task in a training rollout batch.
class RolloutTask {
  const RolloutTask({required this.id, required this.prompt});

  final String id;
  final String prompt;
}

/// Outcome of executing one rollout task.
class RolloutResult {
  const RolloutResult({
    required this.taskId,
    required this.sessionId,
    required this.output,
    required this.tools,
    required this.success,
    required this.latencyMs,
    required this.reward,
  });

  final String taskId;
  final String sessionId;
  final String output;
  final List<String> tools;
  final bool success;
  final int? latencyMs;
  final double reward;

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'session_id': sessionId,
        'output': output,
        'tools': tools,
        'success': success,
        if (latencyMs != null) 'latency_ms': latencyMs,
        'reward': reward,
      };
}

/// Executes a single rollout task against the agent. Hosts wire this to
/// `TikoRuntime.chatWithStatus` (or a test double); the pipeline itself never
/// depend on a concrete runtime.
typedef RolloutExecutor = Future<({String output, List<String> tools, bool success, int? latencyMs})>
    Function(RolloutTask task);

/// Computes the scalar reward for one rollout. Defaults to the classic
/// sparse reward: 1.0 for success, 0.0 for failure.
typedef RewardFn = double Function(RolloutResult result);

/// Batch rollout runner (Atropos-style data generation): executes a list of
/// tasks through an injected [RolloutExecutor], logs every turn to a
/// [TrajectoryLogger] under a per-task session id, and returns results in
/// deterministic task order regardless of [concurrency].
///
/// This is the collection half of an RL pipeline: the resulting trajectory
/// JSONL (via [TrajectoryLogger.exportShareGpt]) is what an external trainer
/// such as Atropos/Tinker consumes. Training itself stays out of process.
class BatchRolloutRunner {
  BatchRolloutRunner({
    required this.logger,
    required this.executor,
    this.concurrency = 1,
    this.rewardFn,
    this.sessionPrefix = 'rollout',
  })  : assert(concurrency >= 1),
        assert(sessionPrefix.isNotEmpty);

  final TrajectoryLogger logger;
  final RolloutExecutor executor;
  final int concurrency;
  final RewardFn? rewardFn;
  final String sessionPrefix;

  Future<List<RolloutResult>> run(List<RolloutTask> tasks) async {
    final results = List<RolloutResult?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tasks.length) return;
        final task = tasks[index];
        final sessionId = '$sessionPrefix-${task.id}';
        final stopwatch = Stopwatch()..start();
        try {
          final outcome = await executor(task);
          stopwatch.stop();
          final result = RolloutResult(
            taskId: task.id,
            sessionId: sessionId,
            output: outcome.output,
            tools: outcome.tools,
            success: outcome.success,
            latencyMs: outcome.latencyMs ?? stopwatch.elapsedMilliseconds,
            reward: 0,
          );
          final rewarded = RolloutResult(
            taskId: result.taskId,
            sessionId: result.sessionId,
            output: result.output,
            tools: result.tools,
            success: result.success,
            latencyMs: result.latencyMs,
            reward: (rewardFn ?? _defaultReward)(result),
          );
          results[index] = rewarded;
          await logger.logTurn(
            sessionId: sessionId,
            input: task.prompt,
            output: outcome.output,
            tools: outcome.tools,
            latencyMs: rewarded.latencyMs,
            success: outcome.success,
          );
        } catch (e) {
          stopwatch.stop();
          final failed = RolloutResult(
            taskId: task.id,
            sessionId: sessionId,
            output: 'rollout error: $e',
            tools: const [],
            success: false,
            latencyMs: stopwatch.elapsedMilliseconds,
            reward: 0,
          );
          results[index] = failed;
          await logger.logTurn(
            sessionId: sessionId,
            input: task.prompt,
            output: failed.output,
            tools: const [],
            latencyMs: failed.latencyMs,
            success: false,
          );
        }
      }
    }

    final workers = tasks.isEmpty ? 0 : concurrency.clamp(1, tasks.length);
    if (workers > 0) {
      await Future.wait(List.generate(workers, (_) => worker()));
    }
    return results.whereType<RolloutResult>().toList();
  }

  static double _defaultReward(RolloutResult result) =>
      result.success ? 1.0 : 0.0;
}

/// Trajectory compression for training datasets: shrinks ShareGPT-format
/// JSONL by capping every turn value and dropping rows that carry no
/// learning signal (empty conversations). Source files are never modified.
abstract final class TrajectoryCompressor {
  /// Reads [inputPath] (ShareGPT JSONL), writes a compressed copy to
  /// [outputPath]. Returns the number of rows written.
  static Future<int> compress(
    String inputPath,
    String outputPath, {
    int maxCharsPerTurn = 1200,
    int maxTurnsPerConversation = 40,
  }) async {
    final input = File(inputPath);
    if (!input.existsSync()) return 0;
    final out = File(outputPath);
    await Directory(
      inputPath.contains('/') || inputPath.contains('\\')
          ? inputPath.substring(0, inputPath.lastIndexOf(RegExp(r'[/\\]')))
          : '.',
    ).create(recursive: true);
    final sink = out.openWrite(mode: FileMode.writeOnly);
    var written = 0;
    try {
      await for (final line in input
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        Map<String, dynamic> row;
        try {
          row = jsonDecode(trimmed) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final raw = (row['conversations'] as List?) ?? const [];
        var turns = raw
            .whereType<Map>()
            .map((t) => {
                  'from': (t['from'] ?? '').toString(),
                  'value': _cap((t['value'] ?? '').toString(), maxCharsPerTurn),
                })
            .toList();
        if (turns.length > maxTurnsPerConversation) {
          turns = turns.sublist(0, maxTurnsPerConversation);
        }
        if (turns.isEmpty) continue;
        row['conversations'] = turns;
        sink.write('${jsonEncode(row)}\n');
        written++;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return written;
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
