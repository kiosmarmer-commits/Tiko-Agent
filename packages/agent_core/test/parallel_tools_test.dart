import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  final context = ToolContext(
    session: Session(id: 'parallel', channel: 'test', userKey: 'test'),
    workspacePath: '.',
  );

  test(
    'only explicitly safe contiguous calls overlap; unsafe calls are barriers',
    () async {
      final executor = _TrackingExecutor();
      final runner = ParallelToolRunner(executor);
      final calls = [
        _call('safe_a', '1'),
        _call('safe_b', '2'),
        _call('unsafe', '3'),
        _call('safe_c', '4'),
      ];

      final results = await runner.runAll(
        calls,
        context,
        parallel: true,
        isParallelSafe: (call) => call.name.startsWith('safe_'),
      );

      expect(executor.maxActive, 2);
      expect(executor.unsafeStartedWithActive, 0);
      expect(results.map((item) => item.call.id), ['1', '2', '3', '4']);
      expect(results.map((item) => item.result.callId), ['1', '2', '3', '4']);
    },
  );

  test('parallel=false serializes even explicitly safe calls', () async {
    final executor = _TrackingExecutor();
    final runner = ParallelToolRunner(executor);
    await runner.runAll(
      [_call('safe_a', '1'), _call('safe_b', '2'), _call('safe_c', '3')],
      context,
      parallel: false,
      isParallelSafe: (_) => true,
    );
    expect(executor.maxActive, 1);
  });

  test(
    'executor exception becomes a per-call error and does not abort later calls',
    () async {
      final runner = ParallelToolRunner(_ThrowingExecutor());
      final results = await runner.runAll(
        [_call('throws', '1'), _call('next', '2')],
        context,
        parallel: false,
      );
      expect(results, hasLength(2));
      expect(results.first.result.isError, isTrue);
      expect(results.first.result.callId, '1');
      expect(results.last.result.isError, isFalse);
    },
  );
}

ToolCall _call(String name, String id) =>
    ToolCall(id: id, name: name, args: const {});

class _TrackingExecutor implements ToolExecutor {
  int active = 0;
  int maxActive = 0;
  int? unsafeStartedWithActive;

  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    if (call.name == 'unsafe') unsafeStartedWithActive = active;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return ToolResult(callId: '', content: call.name);
    } finally {
      active--;
    }
  }
}

class _ThrowingExecutor implements ToolExecutor {
  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    if (call.name == 'throws') throw StateError('test failure');
    return ToolResult(callId: call.id, content: 'ok');
  }
}
