import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _StaticGate implements PermissionGate {
  _StaticGate(this.verdict);
  final PermissionVerdict verdict;
  final List<ToolCall> checked = [];

  @override
  Future<PermissionResult> check(ToolCall call, Session session) async {
    checked.add(call);
    return PermissionResult(verdict, reason: verdict == PermissionVerdict.denied ? 'nope' : null);
  }
}

class _RecordingExecutor implements ToolExecutor {
  final results = <String, ToolResult>{};

  @override
  Future<ToolResult> run(ToolCall call, ToolContext ctx) async {
    return results[call.name] ??
        ToolResult(callId: call.id, content: 'no impl: ${call.name}', isError: true);
  }
}

ToolContext _ctx() => ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: '/tmp',
    );

void main() {
  test('chains steps and substitutes templated args from earlier outputs',
      () async {
    final executor = _RecordingExecutor()
      ..results['list_dir'] = const ToolResult(
        callId: '',
        content: '{"files": ["a.txt", "b.txt"]}',
      )
      ..results['read_file'] = const ToolResult(callId: '', content: 'isi a.txt');
    final gate = _StaticGate(PermissionVerdict.allowed);
    final tool = ExecuteCodeTool(executor: executor, gate: gate);

    final result = await tool.run({
      'steps': [
        {
          'tool': 'list_dir',
          'args': {'path': '.'},
          'as': 'listing',
        },
        {
          'tool': 'read_file',
          'args': {'path': '{{listing.files.0}}'},
        },
      ],
    }, _ctx());

    expect(result.isError, isFalse);
    expect(result.content, contains('"completed": true'));
    expect(gate.checked.map((c) => c.name), containsAll(['list_dir', 'read_file']));
    final second = gate.checked[1];
    expect(second.args['path'], 'a.txt');
  });

  test('denied step aborts the program fail-closed', () async {
    final executor = _RecordingExecutor()
      ..results['shell'] = const ToolResult(callId: '', content: 'ok');
    final gate = _StaticGate(PermissionVerdict.denied);
    final tool = ExecuteCodeTool(executor: executor, gate: gate);

    final result = await tool.run({
      'steps': [
        {'tool': 'shell', 'args': {'cmd': 'ls'}},
        {'tool': 'shell', 'args': {'cmd': 'rm'}},
      ],
    }, _ctx());

    expect(result.isError, isTrue);
    expect(result.content, contains('ditolak permission gate'));
    expect(gate.checked, hasLength(1));
  });

  test('needsConfirm step aborts and points to the direct-approval path',
      () async {
    final executor = _RecordingExecutor();
    final gate = _StaticGate(PermissionVerdict.needsConfirm);
    final tool = ExecuteCodeTool(executor: executor, gate: gate);

    final result = await tool.run({
      'steps': [
        {'tool': 'shell', 'args': {'cmd': 'ls'}},
      ],
    }, _ctx());

    expect(result.isError, isTrue);
    expect(result.content, contains('butuh approval'));
    expect(executor.results.isEmpty, isTrue);
  });

  test('unknown template variable aborts before execution', () async {
    final executor = _RecordingExecutor();
    final gate = _StaticGate(PermissionVerdict.allowed);
    final tool = ExecuteCodeTool(executor: executor, gate: gate);

    final result = await tool.run({
      'steps': [
        {
          'tool': 'read_file',
          'args': {'path': '{{missing.field}}'},
        },
      ],
    }, _ctx());

    expect(result.isError, isTrue);
    expect(result.content, contains('tidak dikenal'));
    expect(gate.checked, isEmpty);
  });

  test('step budget is enforced', () async {
    final tool = ExecuteCodeTool(executor: _RecordingExecutor(), gate: _StaticGate(PermissionVerdict.allowed));
    final result = await tool.run({
      'steps': [
        for (var i = 0; i < 9; i++)
          {'tool': 'calc', 'args': {'expr': '1+1'}},
      ],
    }, _ctx());
    expect(result.isError, isTrue);
    expect(result.content, contains('batas 8 step'));
  });

  test('failing step output marks the program as errored', () async {
    final executor = _RecordingExecutor()
      ..results['web_fetch'] = const ToolResult(
        callId: '',
        content: 'HTTP 500',
        isError: true,
      );
    final tool = ExecuteCodeTool(
      executor: executor,
      gate: _StaticGate(PermissionVerdict.allowed),
    );
    final result = await tool.run({
      'steps': [
        {'tool': 'web_fetch', 'args': {'url': 'http://x'}},
        {'tool': 'calc', 'args': {'expr': '1'}},
      ],
    }, _ctx());
    expect(result.isError, isTrue);
    expect(result.content, contains('gagal'));
  });
}
