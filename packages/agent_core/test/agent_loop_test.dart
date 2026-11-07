import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  late List<String> replies;
  late Session session;

  setUp(() {
    replies = [];
    session = Session(id: 'test-session', channel: 'cli', userKey: 'user1');
  });

  Future<void> runScenario(MockScenario scenario, String input) async {
    final mock = MockLlmProvider(scenario: scenario);
    final router = Router(providers: {'mock': mock}, defaultProviderId: 'mock');
    final loop = AgentLoop(
      router: router,
      contextBuilder: ContextBuilder(),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: MockToolExecutor(),
      memory: NoopMemory(),
      reply: (m, text) async => replies.add(text),
      config: const AgentConfig(maxIterations: 8, maxToolCalls: 10),
    );
    final msg = InboundMessage(
      channel: 'cli',
      userKey: 'user1',
      sessionKey: 'cli:user1',
      text: input,
    );
    await loop.handle(msg, session);
  }

  test('scenario 1: plain text reply (no tools)', () async {
    await runScenario(MockScenario.plain, 'Halo');
    expect(replies, isNotEmpty);
    expect(replies.first, contains('mock agent'));
  });

  test('scenario 2: single tool call then final answer', () async {
    await runScenario(MockScenario.singleTool, 'berapa waktu sekarang?');
    expect(replies, isNotEmpty);
    expect(replies.first, contains('2026-11-04'));
  });

  test('scenario 3: multi-step tool calling', () async {
    await runScenario(MockScenario.multiTool, 'hitung 2+3 lalu waktu');
    expect(replies, isNotEmpty);
    expect(replies.first, contains('5'));
  });

  test('loop detector stops identical repeated tool calls', () async {
    await runScenario(MockScenario.loopTrap, 'loop test');
    expect(replies, isNotEmpty);
    expect(replies.first.toLowerCase(), contains('loop'));
  });

  test('only explicit user remember requests are promoted to trusted memory', () async {
    final memory = _RecordingMemory();
    final mock = MockLlmProvider(scenario: MockScenario.plain);
    final loop = AgentLoop(
      router: Router(providers: {'mock': mock}, defaultProviderId: 'mock'),
      contextBuilder: ContextBuilder(),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: MockToolExecutor(),
      memory: memory,
      reply: (m, text) async => replies.add(text),
    );

    Future<void> send(String text) => loop.handle(
      InboundMessage(channel: 'cli', userKey: 'user1', sessionKey: 'cli:user1', text: text),
      session,
    );

    await send('Halo, apa kabar?');
    expect(memory.facts, isEmpty);
    await send('Tolong ingat saya lebih suka jawaban bahasa Indonesia.');
    expect(memory.facts, hasLength(1));
    expect(memory.facts.single.provenance, Provenance.user);
    expect(memory.facts.single.state, 'active');
  });

  test('provider stream errors remain failures even when Done follows', () async {
    final provider = _ErrorProvider();
    final router = Router(providers: {'error': provider}, defaultProviderId: 'error');
    final loop = AgentLoop(
      router: router,
      contextBuilder: ContextBuilder(),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: MockToolExecutor(),
      memory: NoopMemory(),
      reply: (m, text) async => replies.add(text),
      config: const AgentConfig(maxIterations: 2),
    );
    await loop.handle(
      InboundMessage(channel: 'cli', userKey: 'u', sessionKey: 's', text: 'halo'),
      session,
    );
    expect(replies.single, contains('Provider gagal'));
    expect(replies.single, isNot(contains('provider offline')));
    expect(loop.lastTurnSucceeded, isFalse);
  });

  test('iteration exhaustion is not recorded as a successful skill use', () async {
    final mock = MockLlmProvider(scenario: MockScenario.singleTool);
    final registry = SkillRegistry();
    final skill = Skill(
      slug: 'waktu',
      name: 'waktu',
      description: 'gunakan datetime',
      body: 'jawab waktu',
      triggers: ['waktu'],
      status: SkillStatus.trial,
    );
    registry.register(skill);
    final loop = AgentLoop(
      router: Router(providers: {'mock': mock}, defaultProviderId: 'mock'),
      contextBuilder: ContextBuilder(skillRegistry: registry),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: MockToolExecutor(),
      memory: NoopMemory(),
      reply: (m, text) async => replies.add(text),
      config: const AgentConfig(maxIterations: 1, maxToolCalls: 10),
      skillRegistry: registry,
    );
    await loop.handle(
      InboundMessage(
        channel: 'cli', userKey: 'user1', sessionKey: 'cli:user1', text: 'waktu sekarang',
      ),
      session,
    );
    expect(skill.uses, 1);
    expect(skill.successes, 0);
    expect(replies, isEmpty);
  });
}

class _ErrorProvider implements LlmProvider {
  @override
  String get id => 'error';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    yield const LlmError('provider offline');
    // Some transports still emit Done after an Error; the error must survive.
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}


class _RecordingMemory implements MemoryStore {
  final List<Fact> facts = [];

  @override
  Future<void> addMessage(Message message) async {}

  @override
  Future<void> afterTurn(Session session) async {}

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async => const [];

  @override
  Future<void> upsertFact(Fact fact) async {
    facts.add(fact);
  }
}
