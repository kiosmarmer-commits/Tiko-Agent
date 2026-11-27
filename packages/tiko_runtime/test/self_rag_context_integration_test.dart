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
    return const ToolResult(callId: '', content: 'ok');
  }
}

void main() {
  late Directory tmp;
  late RagPipeline rag;

  final session = Session(
    id: 'selfrag-test',
    channel: 'cli',
    userKey: 'tester',
  );
  RouteDecision route() =>
      RouteDecision(llm: MockLlmProvider(), needTools: true);

  InboundMessage msg(String text) => InboundMessage(
    channel: 'cli',
    userKey: 'tester',
    sessionKey: 'selfrag-test',
    text: text,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('self_rag_ctx');
    final dense = BruteForceVectorIndex();
    final lexical = FtsIndex('${tmp.path}/rag_fts.json');
    await lexical.load();
    rag = RagPipeline(dense: dense, lexical: lexical);
    await rag.ingest(
      'wiki-kucing',
      'Kucing adalah hewan mamalia yang suka tidur siang di sofa.',
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ToolRegistry buildRegistry() {
    final registry = ToolRegistry();
    registry.registerAll([_FakeTool('tool_a'), _FakeTool('tool_b')]);
    return registry;
  }

  RuntimeContext context({
    SelfRagController? gate,
    List<SelfRagAssessment>? captured,
  }) => RuntimeContext(
    buildRegistry(),
    memory: InMemoryStore(),
    ragPipeline: rag,
    selfRagGate: gate,
    onRagGate: captured == null ? null : (a) => captured.add(a),
  );

  test(
    'gate menerima passage relevan: blok konteks masuk system prompt',
    () async {
      final captured = <SelfRagAssessment>[];
      final ctx = await context(
        gate: const SelfRagController(),
        captured: captured,
      ).build(session, msg('kucing tidur siang'), route());

      expect(
        ctx.systemPrompt,
        contains('Konteks relevan dari indeks dokumen:'),
      );
      expect(ctx.systemPrompt, contains('wiki-kucing'));
      expect(captured, hasLength(1));
      expect(captured.single.accepted, isTrue);
    },
  );

  test(
    'gate menolak passage tak relevan: blok konteks tidak masuk prompt',
    () async {
      final captured = <SelfRagAssessment>[];
      final ctx = await context(
        gate: const SelfRagController(),
        captured: captured,
      ).build(session, msg('resep rendang santan kelapa'), route());

      expect(
        ctx.systemPrompt,
        isNot(contains('Konteks relevan dari indeks dokumen:')),
      );
      expect(captured, hasLength(1));
      expect(captured.single.accepted, isFalse);
      expect(captured.single.toJson()['status'], 'rejected');
    },
  );

  test(
    'tanpa gate perilaku lama: hasil retrieval tetap masuk prompt',
    () async {
      final captured = <SelfRagAssessment>[];
      final ctx = await context(
        captured: captured,
      ).build(session, msg('kucing tidur siang'), route());

      expect(
        ctx.systemPrompt,
        contains('Konteks relevan dari indeks dokumen:'),
      );
      expect(captured, isEmpty);
    },
  );
}
