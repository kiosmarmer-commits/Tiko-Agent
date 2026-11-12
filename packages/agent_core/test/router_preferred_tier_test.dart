import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

class _MockProvider extends LlmProvider {
  _MockProvider(this.pid, {this.toolCalling = false});

  final String pid;
  final bool toolCalling;

  @override
  String get id => pid;

  @override
  Capabilities get capabilities =>
      Capabilities(toolCalling: toolCalling, streaming: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) => const Stream.empty();
}

class _SpyRouter extends Router {
  _SpyRouter({required super.providers, super.tierProviders});

  @override
  Future<RouteDecision> route(
    String text,
    Session session, {
    int? preferredTier,
  }) {
    lastPreferredTier = preferredTier;
    return super.route(text, session, preferredTier: preferredTier);
  }

  int? lastPreferredTier;
}

void main() {
  Session session() => Session(id: 's', channel: 'cli', userKey: 'u');

  test('preferredTier overrides the text-computed tier', () async {
    final router = Router(
      providers: {
        'light': _MockProvider('light'),
        'heavy': _MockProvider('heavy', toolCalling: true),
      },
      defaultProviderId: 'heavy',
      tierProviders: {1: 'light', 3: 'heavy'},
    );

    final plain = await router.route('Halo', session());
    expect(plain.tier, 1);

    final pinned = await router.route('Halo', session(), preferredTier: 3);
    expect(pinned.tier, 3);
    expect(pinned.providerId, 'heavy');
    expect(pinned.reason, contains('preferred tier=3'));
  });

  test('preferredTier is clamped to 0..3', () async {
    final router = Router(
      providers: {'mock': _MockProvider('mock')},
      defaultProviderId: 'mock',
    );
    final d = await router.route('Halo', session(), preferredTier: 99);
    expect(d.tier, 3);
  });

  test('null preferredTier keeps text-based routing', () async {
    final router = Router(
      providers: {'mock': _MockProvider('mock', toolCalling: true)},
      defaultProviderId: 'mock',
    );
    final d = await router.route('tolong carikan file', session());
    expect(d.tier, 2);
    expect(d.needTools, isTrue);
  });

  test('AgentLoop forwards config.preferredTier to the router', () async {
    final spy = _SpyRouter(
      providers: {'mock': _MockProvider('mock', toolCalling: true)},
      tierProviders: {3: 'mock'},
    );
    final loop = AgentLoop(
      router: spy,
      contextBuilder: ContextBuilder(),
      compactor: Compactor(),
      gate: AllowAllGate(),
      executor: MockToolExecutor(),
      memory: NoopMemory(),
      reply: (m, text) async {},
      config: const AgentConfig(preferredTier: 3),
    );
    await loop.handle(
      const InboundMessage(
        channel: 'cli',
        userKey: 'u',
        sessionKey: 'cli:u',
        text: 'Halo',
      ),
      session(),
    );
    expect(spy.lastPreferredTier, 3);
  });
}
