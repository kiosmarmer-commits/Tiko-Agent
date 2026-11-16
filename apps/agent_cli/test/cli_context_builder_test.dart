import 'package:agent_cli/cli_context_builder.dart';
import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _FakeTool extends Tool {
  _FakeTool(this._spec);
  final ToolSpec _spec;

  @override
  ToolSpec get spec => _spec;

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return const ToolResult(callId: 't1', content: 'ok');
  }
}

void main() {
  test('mengiklankan tool dari registry, bukan dari inner builder', () async {
    final registry = ToolRegistry()
      ..register(_FakeTool(
        const ToolSpec(
          name: 'fake_tool',
          description: 'tool palsu untuk test',
          inputSchema: {'type': 'object'},
        ),
      ));

    final builder = CliContextBuilder(
      registry: registry,
      inner: ContextBuilder(systemPrompt: 'prompt khusus'),
    );

    final session = Session(id: 's1', channel: 'cli', userKey: 'u1');
    const msg = InboundMessage(
      channel: 'cli',
      userKey: 'u1',
      sessionKey: 'cli:u1',
      text: 'halo',
    );

    final ctx = await builder.build(
      session,
      msg,
      RouteDecision(llm: MockLlmProvider(scenario: MockScenario.plain)),
    );

    expect(ctx.tools.map((t) => t.name), contains('fake_tool'));
    expect(ctx.systemPrompt, 'prompt khusus');
    expect(ctx.session.id, 's1');
    expect(ctx.messages, isNotEmpty);
  });
}
