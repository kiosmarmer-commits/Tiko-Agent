import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  test('upsert and search facts', () async {
    final store = InMemoryStore();
    await store.upsertFact(
      const Fact(id: '1', text: 'User tinggal di Jakarta', importance: 0.9),
    );
    await store.upsertFact(
      const Fact(id: '2', text: 'Suka bahasa Dart', importance: 0.7),
    );
    final hits = await store.search('Jakarta');
    expect(hits, isNotEmpty);
    expect(hits.first.text, contains('Jakarta'));
  });

  test('rejects secret-like facts', () async {
    final store = InMemoryStore();
    await store.upsertFact(
      const Fact(id: 'x', text: 'api_key=sk-abcdefghijklmnopqrstuvwxyz'),
    );
    expect(store.facts, isEmpty);
  });

  test('brute-force vector topK', () async {
    final idx = BruteForceVectorIndex();
    await idx.upsert('a', [1.0, 0.0, 0.0], {'text': 'a'});
    await idx.upsert('b', [0.9, 0.1, 0.0], {'text': 'b'});
    await idx.upsert('c', [0.0, 1.0, 0.0], {'text': 'c'});
    final hits = await idx.topK([1.0, 0.0, 0.0], 2);
    expect(hits.first.id, 'a');
    expect(hits.length, 2);
  });

  test('hybrid search with embedder', () async {
    final idx = BruteForceVectorIndex();
    final store = InMemoryStore(
      vectorIndex: idx,
      embedder: (t) async {
        final v = List<double>.filled(8, 0);
        for (final c in t.codeUnits) {
          v[c % 8] += 1;
        }
        return v;
      },
    );
    await store.upsertFact(const Fact(id: '1', text: 'preferensi kopi hitam'));
    await store.upsertFact(const Fact(id: '2', text: 'tidak suka teh'));
    final hits = await store.search('kopi');
    expect(hits, isNotEmpty);
  });
}
