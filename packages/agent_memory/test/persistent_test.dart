import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PersistentMemoryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agent_mem_');
    store = PersistentMemoryStore(dataDir: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('persist fact and reload', () async {
    await store.upsertFact(
      const Fact(
        id: '1',
        text: 'Nama pengguna adalah Budi',
        kind: 'preference',
        importance: 0.9,
      ),
    );
    final hits = await store.search('Budi');
    expect(hits, isNotEmpty);

    final store2 = PersistentMemoryStore(dataDir: tmp.path);
    final hits2 = await store2.search('Budi');
    expect(hits2, isNotEmpty);
    expect(hits2.first.text, contains('Budi'));
  });

  test('deleting a fact removes it from JSON persistence and FTS', () async {
    await store.upsertFact(const Fact(
      id: 'delete-me',
      text: 'Temporary preference about blue color',
      provenance: Provenance.user,
      state: 'active',
    ));
    expect(await store.deleteFact('delete-me'), isTrue);
    expect(await store.deleteFact('delete-me'), isFalse);
    final reloaded = PersistentMemoryStore(dataDir: tmp.path);
    expect(await reloaded.search('blue color'), isEmpty);
  });

  test('messages append', () async {
    await store.addMessage(
      Message(sessionId: 's1', role: 'user', content: 'halo'),
    );
    await store.addMessage(
      Message(sessionId: 's1', role: 'assistant', content: 'hai'),
    );
    final msgs = await store.loadMessages('s1');
    expect(msgs, hasLength(2));
  });

  test('provenance, confidence, TTL and state survive JSON reload', () async {
    await store.upsertFact(const Fact(
      id: 'trust-record',
      text: 'Prefer Indonesian language',
      provenance: Provenance.user,
      confidence: 0.93,
      ttlDays: 90,
      state: 'active',
    ));
    final reloaded = PersistentMemoryStore(dataDir: tmp.path);
    final hit = (await reloaded.search('Indonesian language')).single;
    expect(hit.provenance, Provenance.user);
    expect(hit.confidence, 0.93);
    expect(hit.ttlDays, 90);
    expect(hit.state, 'active');
  });
}
