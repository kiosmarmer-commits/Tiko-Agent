import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late Directory temp;
  late BotStore store;
  late BotGroupRouter router;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_bot_group_');
    store = BotStore(dataDir: temp.path);
    await store.load();
    router = BotGroupRouter(store);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  InboundMessage msg(String text, {String chatType = 'group'}) =>
      InboundMessage(
        channel: 'telegram',
        sessionKey: 'tg:100',
        userKey: '42',
        text: text,
        meta: {'chat_type': chatType, 'username': 'budi'},
      );

  test('chat privat bypass walau ada mention bot', () async {
    await store.create(id: 'helper', name: 'Helper');
    final route = router.route(
      text: '@helper tolong',
      isGroup: BotModeGate.isGroup(msg('@helper tolong', chatType: 'private')),
    );
    expect(route.action, BotGroupAction.bypass);
    expect(route.dispatches, isFalse);
  });

  test('grup tanpa bot terdaftar bypass', () {
    final route = router.route(
      text: '@helper tolong',
      isGroup: BotModeGate.isGroup(msg('@helper tolong')),
    );
    expect(route.action, BotGroupAction.bypass);
  });

  test('grup + mention bot -> dispatch profil bot', () async {
    final bot = await store.create(
      id: 'helper',
      name: 'Helper',
      persona: 'Sang asisten',
      model: 'fake',
    );
    final route = router.route(
      text: 'halo @helper tolong carikan data',
      isGroup: BotModeGate.isGroup(msg('halo @helper tolong carikan data')),
    );
    expect(route.dispatches, isTrue);
    expect(route.target!.id, bot.id);
    expect(route.target!.persona, 'Sang asisten');
  });

  test('mention di dalam code fence dan pseudo-mention diabaikan', () async {
    await store.create(id: 'helper', name: 'Helper');
    final route = router.route(
      text: 'lihat: ```@helper``` dan @everyone dan mail a@helper.com',
      isGroup: BotModeGate.isGroup(
          msg('lihat: ```@helper``` dan @everyone dan mail a@helper.com')),
    );
    expect(route.action, BotGroupAction.drop);
  });

  test('grup tanpa mention bot -> drop', () async {
    await store.create(id: 'helper', name: 'Helper');
    final route = router.route(
      text: 'selamat pagi semua',
      isGroup: BotModeGate.isGroup(msg('selamat pagi semua')),
    );
    expect(route.drops, isTrue);
  });
}
