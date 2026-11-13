import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-sync-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/catatan').create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<JsonVaultIndex> freshIndex() async {
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    await index.replaceAll([]);
    return index;
  }

  test('full sync lifecycle: add, modify, delete', () async {
    await File('$vault/catatan/satu.md').writeAsString('---\ntitle: Satu\n---\nisi awal');
    await File('$vault/catatan/dua.md').writeAsString('---\ntitle: Dua\n---\nisi dua');

    final index = await freshIndex();
    final first = await VaultSync.apply(index, vault);
    expect(first.added.length, 2);
    expect(first.updated, isEmpty);
    expect(first.removed, isEmpty);

    final second = await VaultSync.apply(index, vault);
    expect(second.added, isEmpty);
    expect(second.updated, isEmpty);
    expect(second.removed, isEmpty);
    expect(second.unchanged, 2);

    await File('$vault/catatan/satu.md')
        .writeAsString('---\ntitle: Satu\n---\nisi sudah direvisi');
    await File('$vault/catatan/tiga.md').writeAsString('---\ntitle: Tiga\n---\nisi tiga');
    await File('$vault/catatan/dua.md').delete();

    final third = await VaultSync.apply(index, vault);
    expect(third.updated, ['catatan/satu.md']);
    expect(third.added, ['catatan/tiga.md']);
    expect(third.removed, ['catatan/dua.md']);

    final hits = await index.search('direvisi');
    expect(hits.single.path, 'catatan/satu.md');
    final health = await index.health();
    expect(health.noteCount, 2);

    await index.close();
  });

  test('stats() reflects the indexed state for both backends', () async {
    await File('$vault/catatan/satu.md').writeAsString('---\ntitle: Satu\n---\nisi');
    final index = await freshIndex();
    await VaultSync.apply(index, vault);

    final stats = await index.stats();
    expect(stats.keys, ['catatan/satu.md']);
    expect(stats['catatan/satu.md']!.hash, isNotEmpty);
    expect(stats['catatan/satu.md']!.sizeBytes, greaterThan(0));
    await index.close();

    final sqlite = SqliteVaultIndex.tryOpen('$vault/.simpul/index.db');
    if (sqlite == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    final sqliteStats = await sqlite.stats();
    expect(sqliteStats.keys, ['catatan/satu.md']);
    await sqlite.close();
  });
}
