// Hermes fase-14: wiring plan mode ke runtime — `/plan [tugas]` ditulis-ulang
// menjadi prompt plan mode dan dijalankan sebagai turn biasa (riwayat berisi
// prompt, bukan perintah).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp, {String agentExtra = ''}) async {
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
$agentExtra
''');
  return config.path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase14_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('/plan <tugas>: turn berjalan normal, riwayat berisi prompt plan mode',
      () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final out = await rt.chat('/plan buat endpoint health');
    expect(out, isNotEmpty);

    final history = await rt.sessions.recent('cli:default', limit: 10);
    final userMessages = [
      for (final m in history)
        if (m.role == 'user') m.content,
    ];
    expect(
      userMessages.any((m) =>
          m.startsWith('[/plan — plan mode]') &&
          m.contains('buat endpoint health')),
      isTrue,
      reason: 'riwayat harus memuat prompt plan mode yang ditulis-ulang',
    );
    expect(
      userMessages.any((m) => m.trim() == '/plan buat endpoint health'),
      isFalse,
      reason: 'perintah mentah tidak boleh masuk riwayat',
    );
  });

  test('/plan tanpa tugas: prompt infer dari konteks', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final out = await rt.chat('/plan');
    expect(out, isNotEmpty);

    final history = await rt.sessions.recent('cli:default', limit: 10);
    final userMessages = [
      for (final m in history)
        if (m.role == 'user') m.content,
    ];
    expect(
      userMessages.any((m) =>
          m.startsWith('[/plan — plan mode]') &&
          m.contains('infer tugas dari konteks percakapan')),
      isTrue,
    );
  });

  test('/plans bukan perintah plan — diteruskan apa adanya ke model',
      () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    await rt.chat('/plans daftar rencana');
    final history = await rt.sessions.recent('cli:default', limit: 10);
    final userMessages = [
      for (final m in history)
        if (m.role == 'user') m.content,
    ];
    expect(
      userMessages.any((m) => m.contains('/plans daftar rencana')),
      isTrue,
    );
  });
}
