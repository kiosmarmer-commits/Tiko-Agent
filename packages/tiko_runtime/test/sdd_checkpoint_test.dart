import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory ws;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sdd_checkpoint_test');
    ws = Directory('${tmp.path}/ws')..createSync();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  SddCheckpoint ckpt() => SddCheckpoint(storePath: '${tmp.path}/store');

  test('snapshot pertama merekam file teks; skip binary & exclude', () async {
    File('${ws.path}/main.dart').writeAsStringSync('void main() {}');
    Directory('${ws.path}/build').createSync();
    File('${ws.path}/build/out.js').writeAsStringSync('compiled');
    File('${ws.path}/logo.png').writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
    File('${ws.path}/big.bin').writeAsBytesSync(List.filled(2 * 1024 * 1024, 0));

    final c = ckpt();
    final id = await c.create(ws.path, reason: 'sebelum write_file');
    expect(id, isNotEmpty);
    expect(c.snapshots.single.files, contains('main.dart'));
    expect(c.snapshots.single.files, isNot(contains('build/out.js')));
    expect(c.snapshots.single.files, isNot(contains('logo.png')));
    expect(c.snapshots.single.files, isNot(contains('big.bin')));
  });

  test('snapshot kedua hanya menyimpan file yang berubah', () async {
    File('${ws.path}/a.txt').writeAsStringSync('aaa');
    File('${ws.path}/b.txt').writeAsStringSync('bbb');
    final c = ckpt();
    await c.create(ws.path, reason: 'awal');

    File('${ws.path}/a.txt').writeAsStringSync('AAA-berubah');
    final id2 = await c.create(ws.path, reason: 'setelah edit a');
    expect(id2, isNotEmpty);
    expect(c.snapshots.last.files, ['a.txt']);
  });

  test('tidak ada perubahan → id kosong', () async {
    File('${ws.path}/a.txt').writeAsStringSync('aaa');
    final c = ckpt();
    await c.create(ws.path);
    final id = await c.create(ws.path, reason: 'tanpa perubahan');
    expect(id, isEmpty);
    expect(c.snapshots.length, 1);
  });

  test('restore mengembalikan isi file ke versi snapshot', () async {
    final c = ckpt();
    File('${ws.path}/app.txt').writeAsStringSync('versi 1');
    final id = await c.create(ws.path, reason: 'versi 1');

    File('${ws.path}/app.txt').writeAsStringSync('versi 2 rusak');
    final n = await c.restore(id, ws.path);
    expect(n, 1);
    expect(File('${ws.path}/app.txt').readAsStringSync(), 'versi 1');
  });

  test('restore aman: file baru setelah snapshot tidak dihapus', () async {
    final c = ckpt();
    File('${ws.path}/old.txt').writeAsStringSync('old');
    final id = await c.create(ws.path);

    File('${ws.path}/new.txt').writeAsStringSync('new');
    await c.restore(id, ws.path);
    expect(File('${ws.path}/new.txt').existsSync(), isTrue);
    expect(File('${ws.path}/old.txt').readAsStringSync(), 'old');
  });

  test('prune membatasi jumlah snapshot ke maxCheckpoints', () async {
    final c = SddCheckpoint(storePath: '${tmp.path}/store', maxCheckpoints: 3);
    for (var i = 0; i < 5; i++) {
      File('${ws.path}/f.txt').writeAsStringSync('gen-$i');
      final id = await c.create(ws.path, reason: 'gen $i');
      expect(id, isNotEmpty,
          reason: 'gen $i harus menghasilkan snapshot baru');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(c.snapshots.length, 3);
    expect(Directory('${tmp.path}/store').listSync().length, 3);
    expect(c.snapshots.first.reason, 'gen 2');
    expect(c.snapshots.last.reason, 'gen 4');
  });

  test('store bertahan lintas instance (durabel)', () async {
    File('${ws.path}/persist.txt').writeAsStringSync('p');
    final id = await ckpt().create(ws.path, reason: 'persist');

    final c2 = ckpt();
    await c2.restore(id, ws.path);
    expect(c2.snapshots.length, 1);
    expect(c2.snapshots.single.id, id);
  });
}
