import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-watch-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/catatan').create(recursive: true);
    await Directory('$vault/.simpul').create();
    await File('$vault/.simpul/index.json').writeAsString('{}\n');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('snapshot maps tracked notes with mtime and size', () async {
    await File('$vault/catatan/satu.md').writeAsString('isi satu\n');
    final watcher = VaultWatcher(vault);
    final snap = await watcher.snapshot();
    expect(snap.keys, ['catatan/satu.md']);
    expect(snap['catatan/satu.md']!.size, 'isi satu\n'.length);
  });

  test('batches emit changed notes including removals', () async {
    await File('$vault/catatan/satu.md').writeAsString('isi satu\n');
    final watcher = VaultWatcher(vault);
    final received = <VaultWatchBatch>[];
    final subscription =
        watcher.batches(interval: const Duration(milliseconds: 60)).listen(received.add);
    addTearDown(subscription.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await File('$vault/catatan/dua.md').writeAsString('isi dua\n');
    await File('$vault/catatan/satu.md').writeAsString('isi satu revisi\n');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      received.expand((b) => b.paths),
      containsAll(['catatan/dua.md', 'catatan/satu.md']),
    );

    await File('$vault/catatan/dua.md').delete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      received.expand((b) => b.paths),
      contains('catatan/dua.md'),
    );
  });

  test('hidden folders and non-markdown files never appear', () async {
    final watcher = VaultWatcher(vault);
    final received = <VaultWatchBatch>[];
    final subscription =
        watcher.batches(interval: const Duration(milliseconds: 60)).listen(received.add);
    addTearDown(subscription.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    await File('$vault/.simpul/index.json').writeAsString('{"x":1}\n');
    await File('$vault/.obsidian/x.md').create(recursive: true);
    await File('${tmp.path}/luar.txt').writeAsString('di luar vault\n');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received, isEmpty);
  });

  test('relativeNotePath filters hidden segments and non-md', () {
    final watcher = VaultWatcher(vault);
    expect(watcher.relativeNotePath('$vault/catatan/a.md'), 'catatan/a.md');
    expect(watcher.relativeNotePath('$vault/.obsidian/x.md'), isNull);
    expect(watcher.relativeNotePath('$vault/catatan/gambar.png'), isNull);
  });
}
