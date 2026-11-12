import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko-eco');
    await Directory('${temp.path}/skills').create(recursive: true);
    await File('${temp.path}/agent.yaml').writeAsString('''
profile: default
workspace: "."
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('TIKO_FORCE_JSON_MEMORY=1 memaksa backend json-fallback', () async {
    final runtime = await TikoRuntime.create(
      configPath: '${temp.path}/agent.yaml',
      env: {'TIKO_FORCE_JSON_MEMORY': '1'},
    );
    expect(runtime.memoryBackend, contains('json-fallback'));
    await runtime.close();
  });

  test('tanpa env, backend memakai sqlite bila tersedia', () async {
    final runtime = await TikoRuntime.create(
      configPath: '${temp.path}/agent.yaml',
    );
    // Di host dengan libsqlite3 backend = sqlite-fts5; di host eco (Termux,
    // sandbox lokal) tryOpen gagal dan fallback JSON terpilih. Keduanya sah.
    expect(
      runtime.memoryBackend.startsWith('sqlite-fts5') ||
          runtime.memoryBackend.contains('json-fallback'),
      isTrue,
    );
    await runtime.close();
  });
}
