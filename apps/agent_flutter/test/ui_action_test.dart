import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/ui/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server palsu untuk typed GenUI action: status /v1/ui/actions dapat
/// diatur (200 / 501), dan /v1/messages tersedia untuk jalur fallback.
class _ApiServer {
  int uiActionStatus = 200;
  final paths = <String>[];
  final bodies = <String>[];
  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final path = req.uri.path;
        final body = await utf8.decoder.bind(req).join();
        paths.add(path);
        bodies.add(body);
        req.response.headers.contentType = ContentType.json;
        if (path == '/v1/ui/actions') {
          req.response.statusCode = uiActionStatus;
          if (uiActionStatus == 200) {
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'text': 'aksi dijalankan',
            }));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{
              'error': 'ui actions not configured',
            }));
          }
        } else if (path == '/v1/messages') {
          req.response.write(jsonEncode(<String, dynamic>{'text': 'balasan teks'}));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode({'error': 'not found'}));
        }
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

void main() {
  late _ApiServer fake;
  late AgentApiClient client;

  setUp(() async {
    fake = _ApiServer();
    final base = await fake.start();
    client = AgentApiClient(baseUrl: base, token: 't');
  });

  tearDown(() async {
    client.close();
    await fake.close();
  });

  test('sendUiAction sukses: bubble user+assistant terisi balasan typed',
      () async {
    final chat = ChatController(client, sessionKey: 'flutter:default');
    await chat.sendUiAction('submit_form', {'kota': 'Bandung'},
        sessionKey: 'flutter:default');

    expect(chat.messages[0]['role'], 'user');
    expect('${chat.messages[0]['text']}', contains('submit_form'));
    expect(chat.messages[1]['role'], 'assistant');
    expect(chat.messages[1]['text'], 'aksi dijalankan');
    expect(fake.paths.single, '/v1/ui/actions');
    expect(fake.bodies.single, contains('flutter:default'));
  });

  test('sendUiAction 501: fallback ke jalur teks /ui lama', () async {
    fake.uiActionStatus = 501;
    final chat = ChatController(client, sessionKey: 'flutter:default');
    chat.useStreaming = false;
    await chat.sendUiAction('submit_form', {'kota': 'Bandung'},
        sessionKey: 'flutter:default');

    expect(fake.paths, ['/v1/ui/actions', '/v1/messages']);
    final fallbackBody = jsonDecode(fake.bodies.last) as Map<String, dynamic>;
    expect(fallbackBody['text'], contains('/ui submit_form'));
    expect(chat.messages.last['role'], 'assistant');
    expect(chat.messages.last['text'], 'balasan teks');
  });

  test('sendUiAction ditolak 400: pesan system, tanpa pengiriman ulang',
      () async {
    fake.uiActionStatus = 400;
    final chat = ChatController(client, sessionKey: 'flutter:default');
    await chat.sendUiAction('submit_form', const {}, sessionKey: 'flutter:default');

    expect(fake.paths, ['/v1/ui/actions']);
    expect(chat.messages.single['role'], 'system');
    expect('${chat.messages.single['text']}', contains('Gagal mengirim aksi UI'));
  });
}
