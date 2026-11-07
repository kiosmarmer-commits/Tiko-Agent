import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _Gate implements PermissionGate {
  _Gate(this.verdict);
  final PermissionVerdict verdict;
  @override
  Future<PermissionResult> check(ToolCall call, Session session) async =>
      PermissionResult(verdict, reason: 'test');
}

ToolRegistry _registry() =>
    ToolRegistry()..registerAll([CalcTool(), DatetimeTool()]);

void main() {
  test('tiko calc 5+1 -> 6 without any LLM', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    final r = await d.run('calc', ['5+1']);
    expect(r.exitCode, 0);
    expect(r.output, '6');
  });

  test('args are joined: calc 2 + 3', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect((await d.run('calc', ['2', '+', '3'])).output, '5');
  });

  test('missing args -> exit 2; evaluation error -> exit 1', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect((await d.run('calc', [])).exitCode, 2);
    expect((await d.run('calc', ['1/0'])).exitCode, 1);
  });

  test('unknown command is not handled (falls through to chat)', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect((await d.run('hello', [])).handled, isFalse);
  });

  test('direct path does not bypass the policy gate', () async {
    final denied = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.denied),
    );
    expect((await denied.run('calc', ['5+1'])).exitCode, 3);

    final needs = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.needsConfirm),
    );
    expect((await needs.run('calc', ['5+1'])).exitCode, 3);
  });
}
