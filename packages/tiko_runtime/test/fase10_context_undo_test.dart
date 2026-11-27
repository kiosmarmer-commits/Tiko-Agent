// Hermes fase-10: wiring checkpoints + context breakdown ke runtime —
// `/undo` (restore file pra-mutasi), `/context` (breakdown jendela
// konteks), dan pesan jujur bila belum ada data.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 4
''');
  return config.path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase10_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('/undo tanpa checkpoint: pesan jujur, gagal', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/undo');
    expect(out, contains('Tidak ada checkpoint untuk dibatalkan'));
  });

  test('/context sebelum turn: pesan jujur, gagal', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/context');
    expect(out, contains('Breakdown konteks belum tersedia'));
  });

  test('/context setelah satu turn: breakdown ter-render', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    await rt.chat('halo, perkenalkan diri');
    final out = await rt.chat('/context');
    expect(out, contains('Breakdown konteks (estimasi):'));
    expect(out, contains('percakapan:'));
    expect(out, contains('total:'));
  });

  test('/undo memulihkan isi file lama dari batch checkpoint', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final target = File(p.join(temp.path, 'catatan.md'));
    await target.writeAsString('versi awal');
    final batch = rt.checkpointStore.snapshotBatch(
      rt.workspace,
      [('write_file', 'catatan.md')],
    );
    expect(batch, hasLength(1));
    rt.recordCheckpointBatch('cli:default', batch);

    await target.writeAsString('DIOVERWRITE agent');
    final out = await rt.chat('/undo');
    expect(out, contains('dipulihkan'));
    expect(out, contains('catatan.md'));
    expect(await target.readAsString(), 'versi awal');

    // Ledger terkuras: /undo kedua tidak punya checkpoint lagi.
    final out2 = await rt.chat('/undo');
    expect(out2, contains('Tidak ada checkpoint untuk dibatalkan'));
  });

  test('/undo menghapus file yang sebelumnya belum ada', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final batch = rt.checkpointStore.snapshotBatch(
      rt.workspace,
      [('write_file', 'baru.txt')],
    );
    expect(batch, hasLength(1));
    expect(batch.first.existed, isFalse);
    rt.recordCheckpointBatch('cli:default', batch);

    final target = File(p.join(temp.path, 'baru.txt'));
    await target.writeAsString('karya agent');
    final out = await rt.chat('/undo');
    expect(out, contains('dipulihkan'));
    expect(await target.exists(), isFalse);
  });

  test('recordCheckpointBatch membatasi riwayat per sesi (evict tertua)',
      () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    for (var i = 0; i < 25; i++) {
      final batch = rt.checkpointStore.snapshotBatch(
        rt.workspace,
        [('write_file', 'f$i.txt')],
      );
      rt.recordCheckpointBatch('cli:default', batch);
    }
    // 25 push → hanya 20 terakhir; undo pertama memulihkan f24 (terbaru).
    final f24 = File(p.join(temp.path, 'f24.txt'));
    await f24.writeAsString('mutasi');
    final out = await rt.chat('/undo');
    expect(out, contains('f24.txt'));
    expect(await f24.exists(), isFalse,
        reason: 'f24 belum ada saat snapshot → undo menghapus');
    expect(await File(p.join(temp.path, 'f4.txt')).exists(), isFalse,
        reason: 'f4 ter-evict (20 terakhir mulai dari f5)');
  });
}
