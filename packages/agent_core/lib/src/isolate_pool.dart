import 'dart:async';
import 'dart:isolate';

/// Limited concurrency pool for subagent-style work (AGD-06).
///
/// Workers run pure functions in Isolates. Full AgentLoop in Isolate is heavy
/// (serialization); this pool runs string→string tasks with timeout.
class IsolatePool {
  IsolatePool({this.maxWorkers = 2});

  final int maxWorkers;
  int _active = 0;
  final _queue = <_Job>[];

  Future<String> run(
    String Function(String input) fn,
    String input, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final c = Completer<String>();
    _queue.add(_Job(fn, input, c, timeout));
    _pump();
    return c.future;
  }

  void _pump() {
    while (_active < maxWorkers && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _active++;
      _spawn(job).whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  Future<void> _spawn(_Job job) async {
    try {
      // Capture only sendable task values. Capturing [_Job] would also send
      // its Completer to the worker isolate, which is not sendable.
      final fn = job.fn;
      final input = job.input;
      final result = await Isolate.run(() => fn(input)).timeout(job.timeout);
      if (!job.completer.isCompleted) job.completer.complete(result);
    } catch (e) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(e);
      }
    }
  }
}

class _Job {
  _Job(this.fn, this.input, this.completer, this.timeout);
  final String Function(String) fn;
  final String input;
  final Completer<String> completer;
  final Duration timeout;
}

/// Parallel subagent runner: multiple goals at once via Isolate.run where possible.
class ParallelSubagentRunner {
  ParallelSubagentRunner({this.maxParallel = 2});

  final int maxParallel;
  final pool = IsolatePool(maxWorkers: 2);

  /// Run sequential agent loops on host isolate but concurrent futures capped.
  Future<List<String>> runAll(List<Future<String> Function()> tasks) async {
    final results = List<String?>.filled(tasks.length, null);
    var idx = 0;
    final running = <Future>[];

    Future<void> startNext() async {
      if (idx >= tasks.length) return;
      final i = idx++;
      final f = tasks[i]().then((r) => results[i] = r);
      running.add(f);
      await f;
      running.remove(f);
    }

    final starters = <Future>[];
    for (var i = 0; i < maxParallel && i < tasks.length; i++) {
      starters.add(startNext());
    }
    while (idx < tasks.length || running.isNotEmpty) {
      if (running.isEmpty && idx < tasks.length) {
        await startNext();
      } else if (running.isNotEmpty) {
        await Future.any(running);
        if (idx < tasks.length) {
          // ignore: unawaited_futures
          startNext();
        }
      } else {
        break;
      }
    }
    await Future.wait(starters);
    return results.map((e) => e ?? '(empty)').toList();
  }
}
