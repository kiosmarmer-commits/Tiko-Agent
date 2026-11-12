import 'dart:io';

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
        description: 'fake tool $name',
        inputSchema: const {'type': 'object'},
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(callId: '', content: 'ok');
  }
}

void main() {
  final session = Session(id: 'ctx-test', channel: 'cli', userKey: 'tester');
  final message = InboundMessage(
    channel: 'cli',
    userKey: 'tester',
    sessionKey: 'ctx-test',
    text: 'halo',
  );
  final route = RouteDecision(llm: MockLlmProvider(), needTools: true);

  ToolRegistry buildRegistry() {
    final registry = ToolRegistry();
    registry.registerAll([_FakeTool('tool_a'), _FakeTool('tool_b')]);
    return registry;
  }

  test('toolFilter membatasi tool specs yang terlihat model', () async {
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
      toolFilter: {'tool_a'},
    ).build(session, message, route);

    expect(ctx.tools.map((t) => t.name), ['tool_a']);
  });

  test('tanpa toolFilter semua specs diekspos', () async {
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
    ).build(session, message, route);

    expect(ctx.tools.map((t) => t.name).toSet(), {'tool_a', 'tool_b'});
  });

  test('personaPrompt di-append ke system prompt', () async {
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
      personaPrompt: 'SELALU JAWAB DALAM BAHASA JAWA',
    ).build(session, message, route);

    expect(ctx.systemPrompt, contains('SOUL.md'));
    expect(ctx.systemPrompt, contains('SELALU JAWAB DALAM BAHASA JAWA'));
  });

  test('tanpa persona system prompt tidak berubah', () async {
    final base = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
    ).build(session, message, route);
    final withPersona = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
      personaPrompt: null,
    ).build(session, message, route);

    expect(withPersona.systemPrompt, base.systemPrompt);
  });

  test('lesson refleksi diinjeksi ke system prompt (P0-3)', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_reflection_ctx_');
    addTearDown(() => temp.delete(recursive: true));
    final reflection = ReflectionEngine(
      storePath: '${temp.path}/reflection.json',
    );
    reflection.reflect(
      turns: [
        ConversationTurn(
          userMessage: 'deploy gagal',
          assistantMessage: 'terjadi error',
          isSuccessful: false,
        ),
        ConversationTurn(
          userMessage: 'deploy gagal lagi',
          assistantMessage: 'terjadi error lagi',
          isSuccessful: false,
        ),
      ],
      sessionId: 's1',
    );
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
      reflectionEngine: reflection,
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'ctx-test',
        text: 'deploy gagal lagi, kenapa ya',
      ),
      route,
    );

    expect(ctx.systemPrompt, contains('Pelajaran dari pengalaman'));
    expect(ctx.systemPrompt, contains('deploy'));
  });

  test('RAG dan layered memory diinjeksi ke system prompt (P0-4)', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_rag_ctx_');
    addTearDown(() => temp.delete(recursive: true));
    final rag = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${temp.path}/rag_fts.json'),
    );
    await rag.ingest(
      'kb-libur',
      'Kebijakan cuti tahunan diajukan lewat portal HR paling lambat H-7.',
    );
    final layered = LayeredMemory()
      ..add(
        MemoryLayerType.semantic,
        'Preferensi user: jawaban selalu dalam Bahasa Indonesia',
        importance: 0.9,
      );
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
      ragPipeline: rag,
      layeredMemory: layered,
    ).build(
      session,
      InboundMessage(
        channel: 'cli',
        userKey: 'tester',
        sessionKey: 'ctx-test',
        text: 'bagaimana cara mengajukan cuti tahunan',
      ),
      route,
    );

    expect(ctx.systemPrompt, contains('Konteks relevan dari indeks dokumen'));
    expect(ctx.systemPrompt, contains('portal HR'));
    expect(ctx.systemPrompt, contains('Memori berlapis relevan'));
    expect(ctx.systemPrompt, contains('Bahasa Indonesia'));
  });

  test('tanpa engine eksternal context tetap bersih', () async {
    final ctx = await RuntimeContext(
      buildRegistry(),
      memory: InMemoryStore(),
    ).build(session, message, route);

    expect(ctx.systemPrompt, isNot(contains('Pelajaran dari pengalaman')));
    expect(ctx.systemPrompt, isNot(contains('Konteks relevan')));
    expect(ctx.systemPrompt, isNot(contains('Memori berlapis')));
  });
}
