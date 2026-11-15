import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _FakeOpenAI {
  _FakeOpenAI._(this._server);
  final HttpServer _server;

  static Future<_FakeOpenAI> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _FakeOpenAI._(server);
    server.listen((req) async {
      await utf8.decoder.bind(req).drain();
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
    temp = await Directory.systemTemp.createTemp('tiko_model_cmd_');
    fake = await _FakeOpenAI.start();
    configPath = await _prepare(temp, fake.baseUrl);
  });

  tearDown(() async {
    await fake.close();
    await temp.delete(recursive: true);
  });

  test('/model list menampilkan provider dan sesi aktif', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/model');
    expect(out, contains('mock'));
    expect(out, contains('fake'));
    expect(out, contains('sesi ini: mock'));
  });

  test('/model <id> mengalihkan routing sesi; /model default mengembalikan',
      () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final before = await rt.chat('halo');
    expect(before, isNot(contains('dari provider palsu')));

    final switched = await rt.chat('/model fake');
    expect(switched, contains('fake'));

    final after = await rt.chat('halo lagi');
    expect(after, contains('dari provider palsu'));

    final reset = await rt.chat('/model default');
    expect(reset, isNotEmpty);
    final back = await rt.chat('halo lagi dua');
    expect(back, isNot(contains('dari provider palsu')));
  });

  test('/model <id> tidak dikenal ditolak dengan daftar', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/model tidak-ada');
    expect(out, contains('tidak dikenal'));
    expect(out, contains('mock'));
  });

  test('/tools menampilkan registry tool + risiko', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final out = await rt.chat('/tools');
    expect(out, contains('tool terdaftar'));
    expect(out, contains('risk='));
  });
}
