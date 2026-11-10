import 'interfaces.dart';
import 'models.dart';

/// Executes tool calls in source order while allowing explicitly audited,
/// side-effect-free calls in the same contiguous batch to overlap.
///
/// Tools are serialized by default. A caller must opt a tool into parallel
/// execution via [isParallelSafe]; one unsafe call is a barrier that is fully
/// completed before later calls start.
class ParallelToolRunner {
  ParallelToolRunner(this.executor);

  final ToolExecutor executor;

  Future<List<({ToolCall call, ToolResult result})>> runAll(
    List<ToolCall> calls,
    ToolContext ctx, {
    bool parallel = true,
    bool Function(ToolCall call)? isParallelSafe,
  }) async {
    final out = <({ToolCall call, ToolResult result})>[];
    final pendingSafe = <ToolCall>[];

    Future<void> flushSafeBatch() async {
      if (pendingSafe.isEmpty) return;
      final batch = List<ToolCall>.from(pendingSafe);
      pendingSafe.clear();
      out.addAll(await Future.wait(batch.map((call) => _runOne(call, ctx))));
    }

    for (final call in calls) {
      final safe = parallel && (isParallelSafe?.call(call) ?? false);
      if (safe) {
        pendingSafe.add(call);
        continue;
      }
      await flushSafeBatch();
      out.add(await _runOne(call, ctx));
    }

    await flushSafeBatch();
    return out;
  }

  Future<({ToolCall call, ToolResult result})> _runOne(
    ToolCall call,
    ToolContext ctx,
  ) async {
    try {
      final result = await executor.run(call, ctx);
      // Normalize adapters that return an empty call id so downstream traces
      // always retain the model's original invocation identifier.
      final normalized = result.callId == call.id
          ? result
          : ToolResult(
              callId: call.id,
              content: result.content,
              isError: result.isError,
              durationMs: result.durationMs,
            );
      return (call: call, result: normalized);
    } catch (error) {
      return (
        call: call,
        result: ToolResult(
          callId: call.id,
          content: 'Tool executor threw: $error',
          isError: true,
        ),
      );
    }
  }
}
