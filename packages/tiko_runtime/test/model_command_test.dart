import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

class _FakeOpenAI {
  _FakeOpenAI._(this._server);
  final HttpServer _server;

  String? lastChatModel;
  int modelsRequests = 0;

  static Future<_FakeOpenAI> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _FakeOpenAI._(server);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/v1/models') {
        api.modelsRequests++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'fake-1'},
            {'id': 'fake-2'},
            {'id': 'fake-large'},
          ],
        }));
        await req.response.close();
        return;
      }
      if (body.isNotEmpty) {
        final payload = jsonDecode(body) as Map<String, dynamic>;
        api.lastChatModel = payload['model'] as String?;
      }
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

  test('discoverProviderModels: live /models + cache 15 menit', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    final first = await rt.discoverProviderModels('fake');
    expect(first['provider'], 'fake');
    expect(first['discovered'], isTrue);
    expect(first['count'], 3);
    expect(first['models'], containsAll(['fake-1', 'fake-2', 'fake-large']));
    expect(fake.modelsRequests, 1);

    final cached = await rt.discoverProviderModels('fake');
    expect(cached['models'], contains('fake-large'));
    expect(fake.modelsRequests, 1, reason: 'cache 15 menit: satu request saja');
  });

  test('discoverProviderModels: provider tidak dikenal → StateError, '
      'mock → discovered false', () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(
      () => rt.discoverProviderModels('tidak-ada'),
      throwsStateError,
    );

    final mock = await rt.discoverProviderModels('mock');
    expect(mock['discovered'], isFalse);
    expect(mock['models'], isEmpty);
  });

  test('setSessionModel memasang provider + model; chat memakai model itu',
      () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);

    expect(rt.setSessionModel('cli:default', 'fake', 'fake-large'), isTrue);
    expect(rt.sessionModelChoice('cli:default'), 'fake-large');
    expect(rt.effectiveSessionProvider('cli:default'), 'fake');

    final out = await rt.chat('halo');
    expect(out, contains('dari provider palsu'));
    expect(fake.lastChatModel, 'fake-large');

    expect(rt.setSessionModel('cli:default', 'fake', null), isTrue);
    expect(rt.sessionModelChoice('cli:default'), isNull);

    expect(rt.setSessionModel('cli:default', 'tidak-ada', 'x'), isFalse);

    rt.clearSessionProvider('cli:default');
    expect(rt.sessionModelChoice('cli:default'), isNull);
  });

  test('override provider tanpa pilihan model memakai model config',
      () async {
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.setSessionModel('cli:default', 'fake', null), isTrue);
    await rt.chat('halo');
    expect(fake.lastChatModel, 'fake-1');
  });
}
