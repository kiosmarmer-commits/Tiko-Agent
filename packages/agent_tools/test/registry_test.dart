import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late ToolRegistry registry;

  setUp(() {
    registry = ToolRegistry();
    registry.registerAll(createBuiltinTools(workspaceRoot: '.'));
  });

  test('registers builtin tools', () {
    expect(
      registry.names,
      containsAll(['datetime', 'calc', 'list_dir', 'read_file']),
    );
  });

  test('rejects missing required arg', () {
    final err = registry.validateArgs('calc', {});
    expect(err, isNotNull);
    expect(err!, contains('expression'));
  });

  test('accepts valid calc args', () {
    final err = registry.validateArgs('calc', {'expression': '1+1'});
    expect(err, isNull);
  });

  test('unknown tool', () {
    final err = registry.validateArgs('nope', {});
    expect(err, contains('Unknown'));
  });

  test('executor runs datetime', () async {
    final exec = RegistryToolExecutor(registry);
    final result = await exec.run(
      const ToolCall(id: '1', name: 'datetime', args: {}),
      ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: '.',
      ),
    );
    expect(result.isError, isFalse);
    expect(result.content, contains('T')); // ISO timestamp
  });

  test('executor runs calc', () async {
    final exec = RegistryToolExecutor(registry);
    final result = await exec.run(
      const ToolCall(id: '2', name: 'calc', args: {'expression': '(2+3)*4'}),
      ToolContext(
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
        workspacePath: '.',
      ),
    );
    expect(result.isError, isFalse);
    expect(result.content, '20');
  });
}
