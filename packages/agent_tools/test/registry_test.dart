import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('registerAll is atomic when a name collides inside the batch', () {
    final registry = ToolRegistry();
    final first = _TestTool('first');

    expect(
      () => registry.registerAll([first, _TestTool('duplicate'), _TestTool('duplicate')]),
      throwsStateError,
    );
    expect(registry.names, isEmpty);
  });

  test('registerAll is atomic when a name already exists in the registry', () {
    final registry = ToolRegistry()..register(_TestTool('existing'));

    expect(
      () => registry.registerAll([_TestTool('new_tool'), _TestTool('existing')]),
      throwsStateError,
    );
    expect(registry.names, ['existing']);
    expect(registry.get('new_tool'), isNull);
  });

  test('blank or untrimmed names are rejected before registration', () {
    final registry = ToolRegistry();
    expect(() => registry.register(_TestTool('')), throwsArgumentError);
    expect(() => registry.register(_TestTool(' padded ')), throwsArgumentError);
    expect(registry.names, isEmpty);
  });
}

class _TestTool implements Tool {
  _TestTool(this.name);
  final String name;

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: 'test tool',
        inputSchema: const {'type': 'object', 'properties': <String, dynamic>{}},
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async =>
      const ToolResult(callId: '', content: 'ok');
}
