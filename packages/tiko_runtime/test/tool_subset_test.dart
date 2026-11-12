import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _FakeTool extends Tool {
  _FakeTool(this.name);

  final String name;

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: 'fake tool $name untuk pengujian',
        inputSchema: const {'type': 'object'},
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(callId: '', content: 'ok');
  }
}

void main() {
  final session = Session(id: 'subset-test', channel: 'cli', userKey: 'tester');
  final route = RouteDecision(llm: MockLlmProvider(), needTools: true);

  final bigRegistry = () {
    final registry = ToolRegistry();
    registry.registerAll([
      for (var i = 0; i < 30; i++) _FakeTool('tool_${i.toString().padLeft(2, '0')}'),
      _FakeTool('tool_search'),
    ]);
    return registry;
  }();

  test('registry besar: model hanya menerima subset + tool_search', () async {
    final ctx = await RuntimeContext(
      bigRegistry,
      memory: InMemoryStore(),
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'subset-test',
        text: 'tolong pakai tool_07 sekarang',
      ),
      route,
    );

    expect(bigRegistry.specs.length, greaterThan(24));
    expect(ctx.tools.length, lessThan(31));
    expect(ctx.tools.map((t) => t.name), contains('tool_search'));
    expect(ctx.tools.map((t) => t.name), contains('tool_07'));
    expect(ctx.systemPrompt, contains('subset paling relevan'));
    expect(ctx.systemPrompt, contains('tool_search'));
  });

  test('registry kecil: semua specs dikirim tanpa catatan subset', () async {
    final registry = ToolRegistry()
      ..registerAll([_FakeTool('tool_a'), _FakeTool('tool_b')]);
    final ctx = await RuntimeContext(
      registry,
      memory: InMemoryStore(),
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'subset-test',
        text: 'halo',
      ),
      route,
    );

    expect(ctx.tools.length, 2);
    expect(ctx.systemPrompt, isNot(contains('subset paling relevan')));
  });

  test('query tanpa token cocok: fallback ke specs pertama + tool_search',
      () async {
    final ctx = await RuntimeContext(
      bigRegistry,
      memory: InMemoryStore(),
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'subset-test',
        text: 'halo dunia',
      ),
      route,
    );

    expect(ctx.tools.map((t) => t.name), contains('tool_search'));
    expect(ctx.tools, hasLength(21));
  });

  test('toolFilter di bawah threshold tidak mengaktifkan subset', () async {
    final ctx = await RuntimeContext(
      bigRegistry,
      memory: InMemoryStore(),
      toolFilter: {'tool_a', 'tool_search'},
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'subset-test',
        text: 'halo',
      ),
      RouteDecision(llm: MockLlmProvider(), needTools: true),
    );

    expect(ctx.tools.map((t) => t.name), containsAll(['tool_search']));
    expect(ctx.systemPrompt, isNot(contains('subset paling relevan')));
  });

  group('modelTierToRouterTier', () {
    test('pemetaan tier dikenal', () {
      expect(modelTierToRouterTier('light'), 1);
      expect(modelTierToRouterTier('FAST'), 1);
      expect(modelTierToRouterTier('eco'), 1);
      expect(modelTierToRouterTier('standard'), 2);
      expect(modelTierToRouterTier('default'), 2);
      expect(modelTierToRouterTier('heavy'), 3);
      expect(modelTierToRouterTier('reasoning'), 3);
      expect(modelTierToRouterTier('premium'), 3);
    });

    test('tier tidak dikenal -> null (routing teks tetap berlaku)', () {
      expect(modelTierToRouterTier('standard '), 2);
      expect(modelTierToRouterTier('turbo'), isNull);
      expect(modelTierToRouterTier(''), isNull);
    });
  });
}
