import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tiko_sessadv_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FileSessionStore open() =>
      FileSessionStore(path: '${tmp.path}/sessions.json');

  Future<FileSessionStore> seeded() async {
    final store = open();
    await store.getOrCreate('cli:alpha', channel: 'cli', userKey: 'u');
    await store.appendTurn(
      'cli:alpha',
      user: 'halo',
      assistant: 'hai',
      provider: 'openai',
      model: 'gpt-test',
    );
    await store.getOrCreate('cli:beta', channel: 'cli', userKey: 'u');
    await store.appendTurn(
      'cli:beta',
      user: 'cuaca',
      assistant: 'cerah',
      provider: 'anthropic',
    );
    await store.getOrCreate('tg:gamma', channel: 'telegram', userKey: 'u');
    await store.appendTurn('tg:gamma', user: 'tes', assistant: 'ok');
    return store;
  }

  test('setPinned menandai, mengurutkan, dan bertahan setelah reload', () async {
    final store = await seeded();
    expect(await store.setPinned('tg:gamma', true), isTrue);
    expect(await store.setPinned('tidak-ada', true), isFalse);

    final reload = open();
    final all = await reload.list();
    expect(all.first.id, 'tg:gamma');
    expect(all.first.pinned, isTrue);
    expect(all.any((s) => s.pinned), isTrue);
  });

  test('setArchived menyembunyikan sesi dari list aktif dan bertahan', () async {
    final store = await seeded();
    expect(await store.setArchived('cli:beta', true), isTrue);

    final active = await store.list();
    expect(active.firstWhere((s) => s.id == 'cli:beta').archived, isTrue);

    final reload = open();
    final all = await reload.list();
    final archived = all.firstWhere((s) => s.id == 'cli:beta');
    expect(archived.archived, isTrue);
  });

  test('get mengembalikan metadata sesi', () async {
    final store = await seeded();
    final info = await store.get('cli:alpha');
    expect(info, isNotNull);
    expect(info!.provider, 'openai');
    expect(info.model, 'gpt-test');
    expect(await store.get('tidak-ada'), isNull);
  });

  test('duplicate menyalin pesan sebagai fork baru', () async {
    final store = await seeded();
    final copy = await store.duplicate('cli:alpha');
    expect(copy, isNotNull);
    expect(copy!.id, contains('fork-'));
    expect(copy.id, isNot('cli:alpha'));
    expect(copy.turns, greaterThanOrEqualTo(1));
    final messages = await store.recent(copy.id, limit: 20);
    expect(messages.map((m) => m.content), contains('hai'));

    final original = await store.get('cli:alpha');
    expect(original!.turns, copy.turns);

    final again = await store.duplicate('tidak-ada');
    expect(again, isNull);
  });

  test('deleteMany menghapus hanya sesi yang ada dan bertahan', () async {
    final store = await seeded();
    final removed = await store.deleteMany(['cli:alpha', 'tg:gamma', 'hantu']);
    expect(removed, 2);
    final remaining = await store.list();
    expect(remaining.map((s) => s.id), ['cli:beta']);

    final reload = open();
    final still = await reload.list();
    expect(still.map((s) => s.id), ['cli:beta']);
    final empty = await reload.recent('cli:alpha', limit: 10);
    expect(empty, isEmpty);
  });

  test('markTurnOutcome mencatat provider/model dan status gagal', () async {
    final store = await seeded();
    expect(
      await store.markTurnOutcome(
        'cli:alpha',
        ok: false,
        provider: 'groq',
        model: 'llama-fast',
      ),
      isTrue,
    );

    final reload = open();
    final info = await reload.get('cli:alpha');
    expect(info!.lastFailed, isTrue);
    expect(info.provider, 'groq');
    expect(info.model, 'llama-fast');

    await reload.markTurnOutcome('cli:alpha', ok: true);
    final healed = await reload.get('cli:alpha');
    expect(healed!.lastFailed, isFalse);
    expect(await reload.markTurnOutcome('hantu', ok: true), isFalse);
  });

  test('appendTurn gagal ditandai via markTurnOutcome sukses menghapusnya',
      () async {
    final store = await seeded();
    await store.markTurnOutcome('cli:alpha', ok: false, provider: 'openai');
    expect((await store.get('cli:alpha'))!.lastFailed, isTrue);
    await store.appendTurn(
      'cli:alpha',
      user: 'coba lagi',
      assistant: 'berhasil kali ini',
      provider: 'openai',
      model: 'gpt-test',
    );
    final info = await store.get('cli:alpha');
    expect(info!.lastFailed, isFalse);
    expect(info.model, 'gpt-test');
  });
}
