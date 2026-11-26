import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late FileSessionStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_compact_');
    store = FileSessionStore(path: '${temp.path}/sessions.json');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('compactSession mengganti riwayat lama dengan ringkasan + ekor', () async {
    await store.getOrCreate('s1', channel: 'cli', userKey: 'u');
    for (var i = 0; i < 6; i++) {
      await store.appendTurn('s1', user: 'pertanyaan $i', assistant: 'jawaban $i');
    }
    final ok = await store.compactSession(
      's1',
      summary: 'User membahas 6 hal; keputusan: pakai opsi B.',
      keepLastMessages: 2,
    );
    expect(ok, isTrue);

    final recent = await store.recent('s1');
    expect(recent.length, 3, reason: '1 pesan ringkasan + 2 ekor');
    expect(recent.first.role, 'system');
    expect(
      recent.first.content,
      startsWith('Ringkasan percakapan sebelumnya:'),
    );
    expect(recent.first.content, contains('opsi B'));
    expect(recent[1].content, 'pertanyaan 5');
    expect(recent[2].content, 'jawaban 5');

    final info = await store.get('s1');
    expect(info, isNotNull);
  });

  test('keepLastMessages melebihi jumlah pesan → semua disimpan', () async {
    await store.getOrCreate('s2', channel: 'cli', userKey: 'u');
    await store.appendTurn('s2', user: 'u1', assistant: 'a1');
    final ok = await store.compactSession('s2', summary: 'ringkas pendek', keepLastMessages: 50);
    expect(ok, isTrue);
    final recent = await store.recent('s2');
    expect(recent.length, 3, reason: 'ringkasan + 2 pesan asli');
  });

  test('sesi tidak dikenal atau ringkasan kosong → false (fail-open)', () async {
    expect(
      await store.compactSession('tidak-ada', summary: 'x'),
      isFalse,
    );
    await store.getOrCreate('s3', channel: 'cli', userKey: 'u');
    expect(await store.compactSession('s3', summary: '   '), isFalse);
  });

  test('riwayat terkompresi persist ke disk dan dimuat ulang', () async {
    await store.getOrCreate('s4', channel: 'cli', userKey: 'u');
    for (var i = 0; i < 4; i++) {
      await store.appendTurn('s4', user: 'q$i', assistant: 'a$i');
    }
    await store.compactSession('s4', summary: 'ringkasan s4', keepLastMessages: 2);

    final reloaded = FileSessionStore(path: '${temp.path}/sessions.json');
    final recent = await reloaded.recent('s4');
    expect(recent.length, 3);
    expect(recent.first.content, contains('ringkasan s4'));
  });
}
