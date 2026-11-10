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
    expect(r.output, contains('"value":"6"'));
  });

  test('args are joined: calc 2 + 3', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect(
      (await d.run('calc', ['2', '+', '3'])).output,
      contains('"value":"5"'),
    );
  });

  test('format Indonesia: 15% dari 2 juta -> 300000', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    final r = await d.run('calc', ['15%', 'dari', '2', 'juta']);
    expect(r.exitCode, 0);
    expect(r.output, contains('"value":"300000"'));
    expect(r.output, contains('"display":"300.000"'));
  });

  test('missing args -> exit 2; evaluation error -> exit 1', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect((await d.run('calc', [])).exitCode, 2);
    expect((await d.run('calc', ['1/0'])).exitCode, 1);
    expect(
      (await d.run('calc', ['1/0'])).output,
      contains('CALC_E_DIV_ZERO'),
    );
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

  test('flag --scale diteruskan ke tool calc', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    final r = await d.run('calc', ['--scale=4', '2/3']);
    expect(r.exitCode, 0);
    expect(r.output, contains('"value":"0.6667"'));
    expect(
      r.output,
      contains('"precision":{"scale":4,"rounding":"half_even"}'),
    );
  });

  test('flag --rounding=down membulatkan ke bawah', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    final r = await d.run('calc', ['--scale=2', '--rounding=down', '2/3']);
    expect(r.exitCode, 0);
    expect(r.output, contains('"value":"0.66"'));
  });

  test('flag --locale=en membalik peran titik dan koma', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    final r = await d.run('calc', ['--locale=en', '1,500.50', '*', '2']);
    expect(r.exitCode, 0);
    expect(r.output, contains('"value":"3001"'));
  });

  test('flag tidak dikenal / nilai invalid -> exit 2', () async {
    final d = DirectCommandDispatcher(
      registry: _registry(),
      gate: _Gate(PermissionVerdict.allowed),
    );
    expect((await d.run('calc', ['--foo=1', '5+1'])).exitCode, 2);
    expect((await d.run('calc', ['--scale=99', '5+1'])).exitCode, 2);
    expect((await d.run('calc', ['--scale='])).exitCode, 2);
  });
}
