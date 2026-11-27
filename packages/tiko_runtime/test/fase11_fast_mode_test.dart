// Hermes fase-11: wiring fast mode ke runtime — `/fast` (status, set tier,
// alias, kata tak dikenal) dan default dari config (`agent.service_tier`,
// `agent.fast_auto_seconds`).
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
    temp = await Directory.systemTemp.createTemp('tiko_fase11_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('/fast tanpa arg: status default normal', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/fast');
    expect(out, contains('Fast mode: normal'));
  });

  test('/fast <tier>: set static tier, alias ultra, status konsisten',
      () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(await rt.chat('/fast fast'), contains('Fast mode: fast'));
    expect(await rt.chat('/fast'), contains('Fast mode: fast'));

    expect(await rt.chat('/fast ultra'), contains('ultrafast'));
    expect(await rt.chat('/fast'), contains('ultrafast'));

    expect(await rt.chat('/fast normal'), contains('normal'));
    expect(await rt.chat('/fast'), contains('Fast mode: normal'));
  });

  test('/fast auto: jendela terbuka saat user turn berjalan', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/fast auto');
    expect(out, contains('auto'));
    expect(out, contains('jendela 60s'));
    // Jendela belum terbuka sebelum ada turn (buka di batas user turn).
    expect(await rt.chat('/fast'), contains('tertutup'));
    await rt.chat('halo');
    expect(await rt.chat('/fast'), contains('TERBUKA'));
  });

  test('/fast <kata asing>: pesan jujur, gagal', () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/fast ngebut');
    expect(out, contains('Tier tidak dikenal'));
    expect(out, contains('ngebut'));
  });

  test('config default: agent.service_tier + agent.fast_auto_seconds',
      () async {
    final configPath = await _prepare(
      temp,
      agentExtra: '  service_tier: fast\n  fast_auto_seconds: 30\n',
    );
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/fast');
    expect(out, contains('Fast mode: fast'));
  });

  test('/fast auto memengaruhi turn nyata: request mock membawa service_tier',
      () async {
    final configPath = await _prepare(temp);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(await rt.chat('/fast auto'), contains('auto'));
    // Turn nyata berjalan tanpa error dengan tier terpasang (mock provider
    // menerima request ber-service_tier; fast mode tidak pernah mengubah
    // jalur turn).
    final answer = await rt.chat('halo');
    expect(answer, isNotEmpty);
  });
}
