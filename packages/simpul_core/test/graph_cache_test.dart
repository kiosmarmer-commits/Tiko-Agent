import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-graphcache');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('json backend persists graph cache across instances', () async {
    final path = '${tmp.path}/.simpul/index.json';
    final first = JsonVaultIndex(path);
    await first.saveGraphCache(
      kind: 'layout',
      version: 'v1',
      payload: {'positions': {'a.md': [1.5, -2.0]}},
    );
    await first.close();

    final second = JsonVaultIndex(path);
    final hit = await second.loadGraphCache(kind: 'layout', version: 'v1');
    expect(hit, isNotNull);
    expect((hit!['positions'] as Map)['a.md'], [1.5, -2.0]);
    expect(
      await second.loadGraphCache(kind: 'layout', version: 'v2'),
      isNull,
    );
    expect(
      await second.loadGraphCache(kind: 'clusters', version: 'v1'),
      isNull,
    );
    await second.close();
  });

  test('json backend overwrites stale entries atomically', () async {
    final path = '${tmp.path}/.simpul/index.json';
    final index = JsonVaultIndex(path);
    await index.saveGraphCache(kind: 'layout', version: 'v1', payload: {'a': 1});
    await index.saveGraphCache(kind: 'layout', version: 'v2', payload: {'a': 2});
    final hit = await index.loadGraphCache(kind: 'layout', version: 'v2');
    expect(hit, {'a': 2});
    expect(File('$path.tmp').existsSync(), isFalse);
    await index.close();
  });

  test('sqlite backend round-trips versioned cache', () async {
    final sqlite = SqliteVaultIndex.tryOpen('${tmp.path}/.simpul/index.db');
    if (sqlite == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    await sqlite.saveGraphCache(
      kind: 'clusters',
      version: 'louvain-v1',
      payload: {'community_count': 3, 'modularity': 0.42},
    );
    final hit = await sqlite.loadGraphCache(
      kind: 'clusters',
      version: 'louvain-v1',
    );
    expect(hit, isNotNull);
    expect(hit!['community_count'], 3);
    expect(
      await sqlite.loadGraphCache(kind: 'clusters', version: 'louvain-v2'),
      isNull,
    );
    await sqlite.close();
  });
}
