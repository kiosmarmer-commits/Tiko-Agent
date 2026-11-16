import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Langkah skrip respons fake provider: teks biasa atau panggilan tool.
sealed class _Step {}

class _TextStep extends _Step {
  _TextStep(this.content);
  final String content;
}

class _ToolStep extends _Step {
  _ToolStep(this.name, this.arguments);
  final String name;
  final String arguments;
}

class _FakeOpenAI {
  _FakeOpenAI._(this._server);
  final HttpServer _server;
  String lastBody = '';
  var requestCount = 0;
  final List<_Step> script = [];
  List<String> lastAdvertisedTools = [];

  static Future<_FakeOpenAI> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _FakeOpenAI._(server);
    server.listen((req) async {
      api.lastBody = await utf8.decoder.bind(req).join();
      final body = jsonDecode(api.lastBody) as Map<String, dynamic>;
      api.lastAdvertisedTools = (body['tools'] as List<dynamic>? ?? [])
          .map((t) =>
              ((t as Map<String, dynamic>)['function']
                  as Map<String, dynamic>)['name'] as String)
          .toList();
      final step = api.requestCount < api.script.length
          ? api.script[api.requestCount]
          : _TextStep('dari provider palsu');
      api.requestCount++;
      req.response.headers.contentType =
          ContentType.parse('text/event-stream');
      if (step is _TextStep) {
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': step.content},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          })}\n\n',
        );
      } else if (step is _ToolStep) {
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_${api.requestCount}',
                      'function': {
                        'name': step.name,
                        'arguments': step.arguments,
                      },
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        req.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'tool_calls',
              },
            ],
          })}\n\n',
        );
      }
      req.response.write('data: [DONE]\n\n');
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
  default_chat: fake
  chat:
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
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_bot_allowlist_');
    fake = await _FakeOpenAI.start();
    configPath = await _prepare(temp, fake.baseUrl);
    rt = await TikoRuntime.create(configPath: configPath);
  });

  tearDown(() async {
    await rt.close();
    await fake.close();
    await temp.delete(recursive: true);
  });

  test('BotProfile menyimpan dan memuat tool_allowlist', () {
    final b = BotProfile(id: 'helper', name: 'Helper')
        .copyWith(toolAllowlist: ['read_file', 'list_dir']);
    expect(b.toolAllowlist, ['read_file', 'list_dir']);
    final restored = BotProfile.fromJson(b.toJson());
    expect(restored.toolAllowlist, ['read_file', 'list_dir']);
    expect(BotProfile(id: 'x', name: 'x').toolAllowlist, isEmpty);
    final messy = BotProfile.fromJson({
      'id': 'x',
      'name': 'x',
      'tool_allowlist': [' a ', '', 5, 'a'],
    });
    expect(messy.toolAllowlist, ['a']);
  });

  test('bot tanpa allowlist ditolak fail-closed tanpa memanggil provider',
      () async {
    await rt.chatWithStatus('/bot new helper Helper Bot');
    final use = await rt.chatWithStatus('/bot use helper');
    expect(use.success, isTrue);

    final res = await rt.chatWithStatus('halo bot');
    expect(res.success, isFalse);
    expect(res.text, contains('fail-closed'));
    expect(fake.requestCount, 0);
  });

  test('/bot allow memvalidasi nama tool dan menolak yang tidak dikenal',
      () async {
    await rt.chatWithStatus('/bot new helper Helper Bot');
    final bad = await rt.chatWithStatus('/bot allow helper bukan_tool');
    expect(bad.success, isFalse);
    expect(bad.text, contains('bukan_tool'));

    final ok = await rt.chatWithStatus('/bot allow helper read_file, list_dir');
    expect(ok.success, isTrue);
    expect(ok.text, contains('read_file'));

    final show = await rt.chatWithStatus('/bot show helper');
    expect(show.text, contains('read_file'));
    expect(show.text, contains('list_dir'));
  });

  test('bot dengan allowlist berjalan dan hanya melihat tool allowlist',
      () async {
    await rt.chatWithStatus('/bot new helper Helper Bot');
    await rt.chatWithStatus('/bot allow helper read_file');
    await rt.chatWithStatus('/bot use helper');

    final res = await rt.chatWithStatus('tolong jalankan shell echo halo');
    expect(res.success, isTrue, reason: res.text);
    expect(fake.requestCount, 1);
    expect(fake.lastAdvertisedTools, contains('read_file'));
    expect(fake.lastAdvertisedTools, isNot(contains('shell')));
  });

  test('tool di luar allowlist ditolak pada level gate eksekusi', () async {
    fake.script.addAll([
      _ToolStep('shell', '{"command":"echo halo"}'),
      _TextStep('selesai'),
    ]);
    await rt.chatWithStatus('/bot new helper Helper Bot');
    await rt.chatWithStatus('/bot allow helper read_file');
    await rt.chatWithStatus('/bot use helper');

    final res = await rt.chatWithStatus('jalankan shell');
    expect(res.success, isFalse, reason: res.text);
    expect(fake.requestCount, 2);
    expect(fake.lastBody, contains('di luar allowlist bot'));
  });

  test('/bot allow clear mengosongkan allowlist kembali ke fail-closed',
      () async {
    await rt.chatWithStatus('/bot new helper Helper Bot');
    await rt.chatWithStatus('/bot allow helper read_file');
    final cleared = await rt.chatWithStatus('/bot allow helper clear');
    expect(cleared.success, isTrue);
    await rt.chatWithStatus('/bot use helper');

    final res = await rt.chatWithStatus('halo bot');
    expect(res.success, isFalse);
    expect(res.text, contains('fail-closed'));
    expect(fake.requestCount, 0);
  });
}
