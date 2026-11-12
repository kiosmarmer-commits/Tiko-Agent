import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);

  group('MemoryEntry', () {
    test('retention decays with age', () {
      final entry = MemoryEntry(
        id: 'e1',
        layer: MemoryLayerType.episodic,
        text: 'kucing suka tidur',
        createdAt: now,
      );
      expect(entry.retention(now, halfLifeDays: 14), 1.0);
      final after14 = entry.retention(now.add(const Duration(days: 14)),
          halfLifeDays: 14);
      expect(after14, closeTo(0.5, 0.001));
      final after28 = entry.retention(now.add(const Duration(days: 28)),
          halfLifeDays: 14);
      expect(after28, closeTo(0.25, 0.001));
    });

    test('access boost lifts effective score', () {
      final fresh = MemoryEntry(
        id: 'a',
        layer: MemoryLayerType.semantic,
        text: 'fakta',
        createdAt: now,
        importance: 0.5,
      );
      final touched = MemoryEntry(
        id: 'b',
        layer: MemoryLayerType.semantic,
        text: 'fakta',
        createdAt: now,
        importance: 0.5,
        accessCount: 6,
      );
      expect(
        touched.effectiveScore(now, halfLifeDays: 14),
        greaterThan(fresh.effectiveScore(now, halfLifeDays: 14)),
      );
    });

    test('json round trip', () {
      final entry = MemoryEntry(
        id: 'm1',
        layer: MemoryLayerType.procedural,
        text: 'deploy pakai scripts/apply.sh',
        createdAt: now,
        importance: 0.8,
        tags: ['deploy'],
        ownerKey: 'user-1',
      );
      final back = MemoryEntry.fromJson(entry.toJson());
      expect(back.id, 'm1');
      expect(back.layer, MemoryLayerType.procedural);
      expect(back.importance, 0.8);
      expect(back.tags, ['deploy']);
      expect(back.createdAt, entry.createdAt);
    });
  });

  group('LayeredMemory', () {
    LayeredMemory memory() => LayeredMemory(halfLifeDays: 14);

    test('add, retrieve and touch across layers', () {
      final m = memory()
        ..add(MemoryLayerType.episodic, 'user tanya cuaca jakarta',
            sourceSession: 's1', now: now)
        ..add(MemoryLayerType.semantic, 'user tinggal di jakarta',
            importance: 0.9, now: now)
        ..add(MemoryLayerType.procedural, 'deploy pakai apply.sh',
            now: now);
      expect(m.length, 3);
      expect(m.countLayer(MemoryLayerType.semantic), 1);

      final hits = m.retrieve('jakarta', now: now);
      expect(hits, isNotEmpty);
      expect(hits.first.text, contains('jakarta'));
    });

    test('owner scoping excludes other owners', () {
      final m = memory()
        ..add(MemoryLayerType.semantic, 'rahasia user satu',
            ownerKey: 'u1', now: now)
        ..add(MemoryLayerType.semantic, 'rahasia user dua',
            ownerKey: 'u2', now: now);
      final hits = m.retrieve('rahasia', ownerKey: 'u1', now: now);
      expect(hits, hasLength(1));
      expect(hits.single.ownerKey, 'u1');
    });

    test('old weak memories decay below freshly written ones', () {
      final m = memory()
        ..add(MemoryLayerType.semantic, 'fakta lama jarang diakses',
            importance: 0.4, now: now.subtract(const Duration(days: 60)))
        ..add(MemoryLayerType.semantic, 'fakta baru penting',
            importance: 0.8, now: now);
      final hits = m.retrieve('fakta', now: now);
      expect(hits.first.text, 'fakta baru penting');
    });

    test('consolidate promotes strong episodic entries', () {
      final m = memory();
      final entry = m.add(
        MemoryLayerType.episodic,
        'user selalu minta ringkasan pagi',
        importance: 0.8,
        sourceSession: 's1',
        now: now,
      );
      m.touch(entry.id, now: now);
      m.touch(entry.id, now: now);
      m.touch(entry.id, now: now);

      final report = m.consolidate(now: now);
      expect(report.promoted, 1);
      expect(entry.consolidated, isTrue);
      final semantic = m.get('${entry.id}:semantic');
      expect(semantic, isNotNull);
      expect(semantic!.layer, MemoryLayerType.semantic);
      expect(m.countLayer(MemoryLayerType.semantic), 1);
    });

    test('consolidate forgets entries below the decay floor', () {
      final m = memory();
      m.add(MemoryLayerType.episodic, 'detail sepele sekali',
          importance: 0.1, now: now.subtract(const Duration(days: 120)));
      final report = m.consolidate(now: now);
      expect(report.forgotten, 1);
      expect(m.length, 0);
    });

    test('consolidated entries are not promoted twice', () {
      final m = memory();
      final entry = m.add(MemoryLayerType.episodic, 'pola berulang',
          importance: 0.9, now: now);
      for (var i = 0; i < 3; i++) {
        m.touch(entry.id, now: now);
      }
      m.consolidate(now: now);
      final report = m.consolidate(now: now);
      expect(report.promoted, 0);
    });

    test('save and load round trip', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_layers');
      final path = '${dir.path}/layers.json';
      final m = memory()
        ..add(MemoryLayerType.semantic, 'preferensi bahasa indonesia',
            importance: 0.7, now: now);
      await m.save(path);

      final restored = memory();
      await restored.load(path);
      expect(restored.length, 1);
      expect(restored.all.first.text, 'preferensi bahasa indonesia');
      await dir.delete(recursive: true);
    });

    test('load tolerates corrupt files', () async {
      final dir = await Directory.systemTemp.createTemp('tiko_layers');
      final path = '${dir.path}/broken.json';
      await File(path).writeAsString('{not json');
      final m = memory();
      await m.load(path);
      expect(m.length, 0);
      await dir.delete(recursive: true);
    });

    test('stats reports per-layer counts', () {
      final m = memory()
        ..add(MemoryLayerType.episodic, 'a', now: now)
        ..add(MemoryLayerType.semantic, 'b', now: now);
      final stats = m.stats(now: now);
      expect((stats['episodic'] as Map)['count'], 1);
      expect((stats['semantic'] as Map)['count'], 1);
      expect((stats['procedural'] as Map)['count'], 0);
    });

    test('empty text rejected', () {
      expect(() => memory().add(MemoryLayerType.semantic, '   '),
          throwsArgumentError);
    });
  });
}
