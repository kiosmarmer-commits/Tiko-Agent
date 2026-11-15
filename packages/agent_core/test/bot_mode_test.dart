import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

BotRegistry _bots({List<String> researchTools = const ['web_search']}) {
  final agents = AgentRegistry();
  agents.register(AgentSpec(
    id: 'a-research',
    role: AgentRole.researcher,
    systemPrompt: 'be terse',
    toolAllowlist: researchTools,
  ));
  agents.register(const AgentSpec(
    id: 'a-code',
    role: AgentRole.coder,
    systemPrompt: 'write dart',
    toolAllowlist: ['execute_code'],
  ));
  final bots = BotRegistry(agents);
  bots.bind(const BotBinding(handle: 'Riset', agentId: 'a-research'));
  bots.bind(const BotBinding(handle: 'kode', agentId: 'a-code'));
  return bots;
}

void main() {
  test('canonical handle strips @ and lowercases', () {
    expect(BotBinding.canonicalHandle('@RiSet'), 'riset');
    expect(BotBinding.canonicalHandle('bad handle'), isNull);
    expect(BotBinding.canonicalHandle(''), isNull);
  });

  test('bind rejects unknown agent id', () {
    final bots = _bots();
    expect(
      () => bots.bind(const BotBinding(handle: 'x', agentId: 'nope')),
      throwsArgumentError,
    );
  });

  test('bind rejects invalid handle', () {
    final bots = _bots();
    expect(
      () => bots.bind(const BotBinding(handle: 'a b', agentId: 'a-code')),
      throwsArgumentError,
    );
  });

  test('disabled binding does not resolve', () {
    final bots = _bots();
    bots.bind(const BotBinding(
      handle: 'kode', agentId: 'a-code', enabled: false,
    ));
    expect(bots.resolve('kode'), isNull);
    expect(bots.bindingFor('kode')!.enabled, isFalse);
  });

  test('unbind reports whether a binding existed', () {
    final bots = _bots();
    expect(bots.unbind('@RISET'), isTrue);
    expect(bots.unbind('riset'), isFalse);
    expect(bots.resolve('riset'), isNull);
  });

  test('mentions parse in order, deduplicated', () {
    expect(
      MentionParser.parse('@kode then @riset and @kode'),
      <String>['kode', 'riset'],
    );
  });

  test('email is not a mention', () {
    expect(MentionParser.parse('mail user@example.com'), isEmpty);
  });

  test('code spans and fences are ignored', () {
    expect(MentionParser.parse('use `@kode` here'), isEmpty);
    expect(MentionParser.parse('```\n@kode\n```'), isEmpty);
  });

  test('broadcast pseudo-mentions are ignored', () {
    expect(MentionParser.parse('@everyone @here @all'), isEmpty);
  });

  test('routes to the bound AgentSpec', () {
    final route = BotRouter(registry: _bots())
        .route(text: '@riset please', senderHandle: 'human');
    expect(route.allowed, isTrue);
    expect(route.targets.single.id, 'a-research');
    expect(route.targets.single.toolAllowlist, ['web_search']);
  });

  test('a bot never targets itself', () {
    final route = BotRouter(registry: _bots()).route(
      text: '@riset again',
      senderHandle: 'riset',
      senderIsBot: true,
      hop: 1,
    );
    expect(route.allowed, isFalse);
    expect(route.decision, BotRouteDecision.selfTarget);
  });

  test('hop limit stops bot-to-bot chains', () {
    final route = BotRouter(registry: _bots(), maxHops: 2).route(
      text: '@kode',
      senderHandle: 'riset',
      senderIsBot: true,
      hop: 2,
    );
    expect(route.decision, BotRouteDecision.hopLimit);
  });

  test('turn cap is enforced', () {
    final agents = AgentRegistry();
    final bots = BotRegistry(agents);
    final handles = <String>[];
    for (var i = 0; i < 10; i++) {
      agents.register(AgentSpec(
        id: 'a$i',
        role: AgentRole.custom,
        systemPrompt: 'x',
        toolAllowlist: const ['web_search'],
      ));
      bots.bind(BotBinding(handle: 'b$i', agentId: 'a$i'));
      handles.add('@b$i');
    }
    final route = BotRouter(registry: bots, maxTurnsPerMessage: 3)
        .route(text: handles.join(' '), senderHandle: 'human');
    expect(route.targets.length, 3);
  });

  test('host tool inheritance is refused by default', () {
    final route = BotRouter(registry: _bots(researchTools: const []))
        .route(text: '@riset', senderHandle: 'human');
    expect(route.allowed, isFalse);
    expect(route.decision, BotRouteDecision.hostTools);
    expect(route.refused, <String>['riset']);
  });

  test('host tool inheritance can be opted in', () {
    final route = BotRouter(
      registry: _bots(researchTools: const []),
      allowHostToolInheritance: true,
    ).route(text: '@riset', senderHandle: 'human');
    expect(route.allowed, isTrue);
  });

  test('binding json roundtrip', () {
    const binding = BotBinding(handle: 'riset', agentId: 'a-research');
    final back = BotBinding.fromJson(binding.toJson());
    expect(back.handle, binding.handle);
    expect(back.agentId, binding.agentId);
    expect(back.enabled, isTrue);
  });

  test('unknown and disabled handles are skipped silently', () {
    final bots = _bots();
    bots.bind(const BotBinding(
      handle: 'kode', agentId: 'a-code', enabled: false,
    ));
    final route = BotRouter(registry: bots)
        .route(text: '@kode @ghost @riset', senderHandle: 'human');
    expect(route.targets.single.id, 'a-research');
  });
}
