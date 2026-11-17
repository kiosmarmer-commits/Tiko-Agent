import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/ui/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server palsu yang menyajikan transcript sesi dan mencatat request
/// rename/delete untuk diverifikasi.
class _ApiServer {
  final requests = <String>[];
  final methods = <String>[];
  final bodies = <String>[];
  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final path = req.uri.path;
        final method = req.method;
        final body = await utf8.decoder.bind(req).join();
        requests.add(req.uri.toString());
        methods.add(method);
        bodies.add(body);
        req.response.headers.contentType = ContentType.json;
        if (path == '/v1/sessions/flutter%3Aold/messages' ||
            path == '/v1/sessions/flutter:old/messages') {
          if (method == 'GET') {
            req.response.write(jsonEncode(<String, dynamic>{
              'session_id': 'flutter:old',
              'messages': <Map<String, dynamic>>[
                {'role': 'user', 'content': 'halo'},
                {'role': 'assistant', 'content': 'hai juga'},
              ],
              'limit': 50,
              'offset': 0,
            }));
          } else {
            req.response.statusCode = 404;
            req.response.write(jsonEncode({'error': 'not found'}));
          }
        } else if (path == '/v1/sessions/flutter%3Aold' &&
            method == 'PATCH') {
          final ok = (jsonDecode(body) as Map)['title'] == 'Judul baru';
          req.response.statusCode = ok ? 200 : 404;
          req.response.write(jsonEncode(<String, dynamic>{'ok': ok}));
        } else if (path == '/v1/sessions/flutter%3Aold' &&
            method == 'DELETE') {
          req.response.write(jsonEncode(<String, dynamic>{'deleted': true}));
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

  test('fetchSessionMessages mengambil transcript dengan limit/offset',
      () async {
    final messages = await client.fetchSessionMessages('flutter:old',
        limit: 20, offset: 5);
    expect(messages, hasLength(2));
    expect(messages[0]['role'], 'user');
    expect(messages[1]['content'], 'hai juga');
    expect(fake.requests.single, contains('limit=20&offset=5'));
  });

  test('renameSession dan deleteSession memanggil endpoint yang benar',
      () async {
    expect(await client.renameSession('flutter:old', 'Judul baru'), isTrue);
    expect(fake.methods.last, 'PATCH');
    expect(fake.bodies.last, contains('Judul baru'));

    expect(await client.deleteSession('flutter:old'), isTrue);
    expect(fake.methods.last, 'DELETE');
  });

  test('ChatController.openSession mengganti isi chat dengan transcript',
      () async {
    final chat = ChatController(client);
    chat.messages.add({'role': 'user', 'text': 'pesan lama yang harus hilang'});
    await chat.openSession('flutter:old');
    expect(chat.messages.map((m) => '${m['role']}:${m['text']}').toList(),
        ['user:halo', 'assistant:hai juga']);
  });

  test('ChatController.openSession menampilkan error tanpa melempar',
      () async {
    final chat = ChatController(client);
    await chat.openSession('flutter:tidak-ada');
    expect(chat.messages, hasLength(1));
    expect(chat.messages.single['role'], 'system');
    expect('${chat.messages.single['text']}', contains('Gagal memuat'));
  });
}
