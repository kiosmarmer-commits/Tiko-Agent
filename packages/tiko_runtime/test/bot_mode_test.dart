import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _FakeOpenAI {
  _FakeOpenAI._(this._server);
  final HttpServer _server;
  String lastBody = '';

  static Future<_FakeOpenAI> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _FakeOpenAI._(server);
    server.listen((req) async {
      api.lastBody = await utf8.decoder.bind(req).join();
      req.response.headers.contentType =
          ContentType.parse('text/event-stream');
      req.response.write(
        'data: {"choices": [{"delta": {"content": "dari provider palsu"}, '
        '"finish_reason": null}]}\n\n'
        'data: {"choices": [{"delta": {}, "finish_reason": "stop"}], '
        '"usage": {"prompt_tokens": 1, "completion_tokens": 1, '
        '"total_tokens": 2}}\n\n'
        'data: [DONE]\n\n',
      );
      await req.response.close();
    }, onError: (Object _) {});
    return api;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> close() => _server.close(force: true);
}

Future<String> _prepare(Directory temp, String baseUrl) async {
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
    fake:
      type: openai_compat
      base_url: "$baseUrl"
      model: fake-1
agent:
  max_iterations: 4
''');
  return config.path;
}

void main() {
  late Directory temp;
  late _FakeOpenAI fake;
  late String configPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_bot_mode_');
    fake = await _FakeOpenAI.start();
    configPath = await _prepare(temp, fake.baseUrl);
  });

  tearDown(() async {
    await fake.close();
    await temp.delete(recursive: true);
  });

  test('/bot list kosong menampilkan panduan pembuatan', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/bot');
    expect(out, contains('Belum ada bot'));
    expect(out, contains('/bot new'));
  });

  test('/bot new + persona + show membuat dan menampilkan profil', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final created = await rt.chat('/bot new kucing "Kucing Ninja"');
    expect(created, contains('dibuat'));

    final personaSet = await rt.chat(
      '/bot persona kucing Kamu adalah Kucing Ninja yang menjawab singkat.',
    );
    expect(personaSet, contains('diperbarui'));

    final shown = await rt.chat('/bot show kucing');
    expect(shown, contains('Kucing Ninja'));
    expect(shown, contains('Kamu adalah Kucing Ninja'));
  });

  test('/bot use mengikat sesi, /bot off melepas', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    await rt.chat('/bot new kucing "Kucing Ninja"');
    final offWithout = await rt.chat('/bot off');
    expect(offWithout, contains('tidak sedang memakai bot'));

    final activated = await rt.chat('/bot use kucing');
    expect(activated, contains('memakai bot "kucing"'));

    final listing = await rt.chat('/bot list');
    expect(listing, contains('[aktif]'));

    final deactivated = await rt.chat('/bot off');
    expect(deactivated, contains('dinonaktifkan'));
  });

  test('bot aktif menyuntikkan persona dan mengalihkan model ke bot',
      () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final before = await rt.chat('halo');
    expect(before, isNot(contains('dari provider palsu')));

    await rt.chat('/bot new kucing "Kucing Ninja"');
    await rt.chat(
      '/bot persona kucing Kamu adalah Kucing Ninja yang menjawab singkat.',
    );
    await rt.chat('/bot model kucing fake');
    final activated = await rt.chat('/bot use kucing');
    expect(activated, contains('memakai bot "kucing"'));

    final withBot = await rt.chat('halo lewat bot');
    expect(withBot, contains('dari provider palsu'));
    expect(fake.lastBody, contains('Kucing Ninja'));

    await rt.chat('/bot off');
    final after = await rt.chat('halo tanpa bot');
    expect(after, isNot(contains('dari provider palsu')));
  });

  test('/bot dengan id tidak dikenal ditolak', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/bot use hantu');
    expect(out, contains('tidak dikenal'));
  });

  test('profil bot dan binding sesi persisten antar restart', () async {
    final rt1 = await TikoRuntime.create(configPath: configPath);
    await rt1.chat('/bot new kucing "Kucing Ninja"');
    await rt1.chat(
      '/bot persona kucing Kamu adalah Kucing Ninja yang menjawab singkat.',
    );
    await rt1.chat('/bot use kucing');
    await rt1.close();

    final rt2 = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt2.close);
    final listing = await rt2.chat('/bot list');
    expect(listing, contains('kucing'));
    expect(listing, contains('[aktif]'));
    final shown = await rt2.chat('/bot show kucing');
    expect(shown, contains('Kamu adalah Kucing Ninja'));
  });
}
