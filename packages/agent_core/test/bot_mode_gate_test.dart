import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

BotRouter _router({List<String> tools = const ['web_search'], bool bind = true}) {
  final agents = AgentRegistry();
  agents.register(AgentSpec(
    id: 'a-research',
    role: AgentRole.researcher,
    systemPrompt: 'terse',
    toolAllowlist: tools,
  ));
  final bots = BotRegistry(agents);
  if (bind) {
    bots.bind(const BotBinding(handle: 'riset', agentId: 'a-research'));
  }
  return BotRouter(registry: bots);
}

InboundMessage _msg(String text, {Object? type, Object? username}) =>
    InboundMessage(
      channel: 'telegram',
      userKey: '42',
      sessionKey: 'tg:-100',
      text: text,
      meta: {'chat_type': type, 'username': username},
    );

void main() {
  test('private chat bypasses Bot Mode', () {
    final gate = BotModeGate(_router());
    final r = gate.evaluate(_msg('@riset hi', type: 'private'));
    expect(r.action, BotModeAction.bypass);
  });

  test('missing chat_type bypasses Bot Mode', () {
    final r = BotModeGate(_router()).evaluate(_msg('@riset hi'));
    expect(r.action, BotModeAction.bypass);
  });

  test('group without bindings keeps existing behaviour', () {
    final r = BotModeGate(_router(bind: false))
        .evaluate(_msg('hello all', type: 'group'));
    expect(r.action, BotModeAction.bypass);
  });

  test('group mention dispatches to the bound spec', () {
    final r = BotModeGate(_router())
        .evaluate(_msg('@riset look up X', type: 'supergroup'));
    expect(r.dispatches, isTrue);
    expect(r.route!.targets.single.id, 'a-research');
  });

  test('group message without mention is dropped', () {
    final r = BotModeGate(_router())
        .evaluate(_msg('just chatting', type: 'group'));
    expect(r.action, BotModeAction.drop);
    expect(r.reason, 'noMention');
  });

  test('bot cannot summon itself', () {
    final r = BotModeGate(_router()).evaluate(
      _msg('@riset again', type: 'group', username: 'riset'),
      hop: 1,
      senderIsBot: true,
    );
    expect(r.action, BotModeAction.drop);
    expect(r.reason, 'selfTarget');
  });

  test('hop limit terminates chains', () {
    final gate = BotModeGate(BotRouter(
      registry: _router().registry,
      maxHops: 2,
    ));
    final r = gate.evaluate(
      _msg('@riset', type: 'group', username: 'other'),
      hop: 2,
      senderIsBot: true,
    );
    expect(r.reason, 'hopLimit');
  });

  test('host tool inheritance is refused in groups', () {
    final r = BotModeGate(_router(tools: const []))
        .evaluate(_msg('@riset', type: 'group'));
    expect(r.action, BotModeAction.drop);
    expect(r.reason, 'hostTools');
  });

  test('sender falls back to userKey when username absent', () {
    final r = BotModeGate(_router())
        .evaluate(_msg('@riset', type: 'group'));
    expect(r.dispatches, isTrue);
  });

  test('isGroup recognises group and supergroup only', () {
    expect(BotModeGate.isGroup(_msg('x', type: 'group')), isTrue);
    expect(BotModeGate.isGroup(_msg('x', type: 'supergroup')), isTrue);
    expect(BotModeGate.isGroup(_msg('x', type: 'channel')), isFalse);
    expect(BotModeGate.isGroup(_msg('x')), isFalse);
  });
}
