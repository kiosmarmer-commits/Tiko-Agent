import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late String dataDir;

  setUp(() async {
    dataDir =
        await Directory.systemTemp.createTemp('teamshare_test').then((d) => d.path);
  });

  tearDown(() async {
    await Directory(dataDir).delete(recursive: true);
  });

  test('TEAMSHARE-1: canUse — owner kosong publik (backward-compatible)',
      () {
    final legacy = BotProfile(id: 'lama', name: 'Lama');
    expect(legacy.owner, isEmpty);
    expect(legacy.canUse('siapa-pun'), isTrue);
    expect(legacy.canUse(''), isTrue);

    final owned = BotProfile(id: 'pribadi', name: 'Pribadi', owner: 'alice');
    expect(owned.canUse('alice'), isTrue);
    expect(owned.canUse('bob'), isFalse);
    expect(owned.canUse(''), isFalse);

    final shared = owned.copyWith(sharedWith: ['bob', 'carol']);
    expect(shared.canUse('bob'), isTrue);
    expect(shared.canUse('carol'), isTrue);
    expect(shared.canUse('dave'), isFalse);
  });

  test('TEAMSHARE-2: owner + shared_with persist lintas instance', () async {
    final store = BotStore(dataDir: dataDir);
    await store.create(id: 'asisten', name: 'Asisten', owner: 'alice');
    await store.update(
      'asisten',
      (b) => b.copyWith(sharedWith: ['bob']),
    );
    final store2 = BotStore(dataDir: dataDir);
    await store2.load();
    final bot = store2.get('asisten')!;
    expect(bot.owner, 'alice');
    expect(bot.sharedWith, ['bob']);
    expect(bot.canUse('bob'), isTrue);
    expect(bot.canUse('dave'), isFalse);
  });

  test('TEAMSHARE-3: copyWith clearOwner / clearSharedWith', () {
    final bot = BotProfile(
      id: 'x',
      name: 'X',
      owner: 'alice',
      sharedWith: ['bob'],
    );
    final unowned = bot.copyWith(clearOwner: true);
    expect(unowned.owner, isEmpty);
    expect(unowned.sharedWith, ['bob']);
    final private = bot.copyWith(clearSharedWith: true);
    expect(private.owner, 'alice');
    expect(private.sharedWith, isEmpty);
  });

  test('TEAMSHARE-4: unbind bot dihapus juga menghapus binding sesi',
      () async {
    final store = BotStore(dataDir: dataDir);
    await store.create(id: 'hapus', name: 'Hapus', owner: 'alice');
    await store.bind('s-1', 'hapus');
    expect(store.botFor('s-1'), isNotNull);
    await store.delete('hapus');
    expect(store.botFor('s-1'), isNull);
  });

  test('TEAMSHARE-5: JSON roundtrip field baru tidak merusak field lama',
      () {
    final bot = BotProfile(
      id: 'round',
      name: 'Round',
      persona: 'persona lama',
      greeting: 'halo',
      toolAllowlist: ['echo'],
      owner: 'alice',
      sharedWith: ['bob'],
      learnings: ['pelajaran 1'],
    );
    final json = bot.toJson();
    final parsed = BotProfile.fromJson(json);
    expect(parsed.owner, 'alice');
    expect(parsed.sharedWith, ['bob']);
    expect(parsed.learnings, ['pelajaran 1']);
    expect(parsed.persona, 'persona lama');
    expect(parsed.greeting, 'halo');
    expect(parsed.toolAllowlist, ['echo']);

    final legacyJson = BotProfile(id: 'old', name: 'Old').toJson()
      ..remove('owner')
      ..remove('shared_with')
      ..remove('learnings');
    final legacy = BotProfile.fromJson(legacyJson);
    expect(legacy.owner, isEmpty);
    expect(legacy.sharedWith, isEmpty);
    expect(legacy.learnings, isEmpty);
    expect(legacy.canUse('siapa-pun'), isTrue);
  });
}
