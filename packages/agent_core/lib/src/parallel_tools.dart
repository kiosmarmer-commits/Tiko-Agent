import 'models.dart';
import 'interfaces.dart';

/// Run independent tool calls concurrently (same round).
class ParallelToolRunner {
  ParallelToolRunner(this.executor);

  final ToolExecutor executor;

  Future<List<({ToolCall call, ToolResult result})>> runAll(
    List<ToolCall> calls,
    ToolContext ctx, {
    bool parallel = true,
  }) async {
    if (!parallel || calls.length <= 1) {
      final out = <({ToolCall call, ToolResult result})>[];
      for (final c in calls) {
        out.add((call: c, result: await executor.run(c, ctx)));
      }
      return out;
    }
    final futures = calls.map((c) async {
      final r = await executor.run(c, ctx);
      return (call: c, result: r);
    });
    return Future.wait(futures);
  }
}
