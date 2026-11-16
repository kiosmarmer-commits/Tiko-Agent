import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// OpenAI-compat palsu yang menjawab lambat (delay per request) supaya turn
/// pertama masih berjalan saat pesan kedua datang.
class _SlowOpenAI {
  _SlowOpenAI._(this._server);
  final HttpServer _server;
  final requests = <DateTime>[];

  static Future<_SlowOpenAI> start(Duration delay) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = _SlowOpenAI._(server);
    server.listen((req) async {
      await utf8.decoder.bind(req).drain();
      final index = api.requests.length;
      api.requests.add(DateTime.now());
      await Future<void>.delayed(index == 0 ? delay : Duration.zero);
      req.response.headers.contentType = ContentType.parse('text/event-stream');
      if (index == 0) {
        // Fase 1: tool call supaya interrupt jatuh di tool boundary.
        req.response.write(
          'data: {"choices": [{"delta": {"tool_calls": [{"index": 0, '
          '"id": "call_1", "type": "function", "function": '
          '{"name": "calc", "arguments": "{\\"expression\\":\\"1+1\\"}"}}]}, '
          '"finish_reason": null}]}\n\n'
          'data: {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}\n\n'
          'data: [DONE]\n\n',
        );
      } else {
        req.response.write(
          'data: {"choices": [{"delta": {"content": "jawaban lambat"}, '
          '"finish_reason": null}]}\n\n'
          'data: {"choices": [{"delta": {}, "finish_reason": "stop"}], '
          '"usage": {"prompt_tokens": 1, "completion_tokens": 1, '
          '"total_tokens": 2}}\n\n'
          'data: [DONE]\n\n',
        );
      }
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
  default_chat: slow
  chat:
    slow:
      type: openai_compat
      base_url: "$baseUrl"
      model: slow-1
agent:
  max_iterations: 4
  interrupt_redirect: true
''');
  return config.path;
}

void main() {
  test('pesan baru saat sesi sibuk memotong turn dan diproses ulang',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_interrupt_');
    addTearDown(() => temp.delete(recursive: true));
    final slow = await _SlowOpenAI.start(const Duration(seconds: 3));
    addTearDown(slow.close);
    final configPath = await _prepare(temp, slow.baseUrl);

    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    final interruptedEvents = <Map<String, dynamic>>[];
    rt.events.stream.listen((e) {
      if (e.type == 'turn.interrupted') {
        interruptedEvents.add(e.data);
      }
    });

    final first = rt.chatWithStatus(
      'pertanyaan pertama yang lambat',
      sessionId: 'cli:default',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (rt.cancellations.tokenOf('cli:default') == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(rt.cancellations.tokenOf('cli:default'), isNotNull);

    final second = await rt.chatWithStatus(
      'pertanyaan kedua',
      sessionId: 'cli:default',
    );
    expect(second.success, isTrue, reason: second.text);
    expect(second.text, contains('jawaban lambat'));

    final firstResult = await first;
    expect(firstResult.success, isFalse);
    expect(firstResult.text, contains('dibatalkan'));

    expect(interruptedEvents, hasLength(1));
    expect(interruptedEvents.single['session'], 'cli:default');
  });

  test('pesan kedua saat sesi idle tidak menghasilkan event interupsi',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_interrupt_');
    addTearDown(() => temp.delete(recursive: true));
    final slow = await _SlowOpenAI.start(Duration.zero);
    addTearDown(slow.close);
    final configPath = await _prepare(temp, slow.baseUrl);

    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    var interrupted = 0;
    rt.events.stream.listen((e) {
      if (e.type == 'turn.interrupted') interrupted++;
    });

    await rt.chatWithStatus('pertama', sessionId: 'cli:default');
    final second = await rt.chatWithStatus('kedua', sessionId: 'cli:default');
    expect(second.success, isTrue, reason: second.text);
    expect(interrupted, 0);
  });
}
