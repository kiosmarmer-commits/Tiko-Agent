import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory vault;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('simpul_saved_');
  });

  tearDown(() async {
    if (await vault.exists()) await vault.delete(recursive: true);
  });

  test('list empty on fresh vault', () async {
    expect(await SavedSearchStore(vault.path).list(), isEmpty);
  });

  test('save, list sorted, resolve case-insensitive', () async {
    final store = SavedSearchStore(vault.path);
    await store.save('zonk', 'tag:b');
    await store.save('alpha', 'tag:a');
    final list = await store.list();
    expect(list.map((s) => s.name), ['alpha', 'zonk']);
    expect(list.first.query, 'tag:a');
    expect((await store.resolve('ALPHA'))!.query, 'tag:a');
  });

  test('save overwrites same name, keeps others', () async {
    final store = SavedSearchStore(vault.path);
    await store.save('a', 'q1');
    await store.save('b', 'q2');
    await store.save('a', 'q3');
    final list = await store.list();
    expect(list, hasLength(2));
    expect((await store.resolve('a'))!.query, 'q3');
  });

  test('delete removes only target, returns false when absent', () async {
    final store = SavedSearchStore(vault.path);
    await store.save('a', 'q');
    expect(await store.delete('a'), isTrue);
    expect(await store.delete('a'), isFalse);
    expect(await store.list(), isEmpty);
  });

  test('empty name or query rejected', () async {
    final store = SavedSearchStore(vault.path);
    expect(() => store.save('  ', 'q'), throwsArgumentError);
    expect(() => store.save('n', '  '), throwsArgumentError);
  });

  test('persisted as pretty json under .simpul', () async {
    final store = SavedSearchStore(vault.path);
    await store.save('rutin', 'tag:kerja path:jurnal');
    final file = File('${vault.path}/.simpul/searches.json');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('"rutin"'));
    expect(file.existsSync() && !File('${file.path}.tmp').existsSync(), isTrue);
  });
}
