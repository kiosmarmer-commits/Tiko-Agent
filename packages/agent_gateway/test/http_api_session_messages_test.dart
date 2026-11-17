import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late String? capturedLimit;
  late String? capturedOffset;
  late String? deletedId;
  late String? renamedId;
  late String? renamedTitle;

  setUp(() async {
    capturedLimit = null;
    capturedOffset = null;
    deletedId = null;
    renamedId = null;
    renamedTitle = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      sessionMessages: (id, {required int limit, required int offset}) async {
        capturedLimit = '$limit';
        capturedOffset = '$offset';
        return [
          {'role': 'user', 'content': 'halo $id'},
          {'role': 'assistant', 'content': 'hai'},
        ];
      },
      deleteSession: (id) async {
        deletedId = id;
        return id == 's1';
      },
      renameSession: (id, title) async {
        renamedId = id;
        renamedTitle = title;
        return id == 's1' && title.trim().isNotEmpty;
      },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set('content-type', 'application/json');
      if (auth) request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {'status': response.statusCode, 'body': jsonDecode(text) as Map<String, dynamic>};
    } finally {
      client.close(force: true);
    }
  }

  test('GET /v1/sessions/<id>/messages returns transcript page', () async {
    final result = await send('GET', '/v1/sessions/s1/messages?limit=20&offset=5');
    expect(result['status'], 200);
    expect(result['body']['session_id'], 's1');
    expect((result['body']['messages'] as List).length, 2);
    expect(result['body']['messages'][0]['role'], 'user');
    expect(result['body']['messages'][0]['content'], 'halo s1');
    expect(capturedLimit, '20');
    expect(capturedOffset, '5');
  });

  test('GET messages defaults limit/offset and clamps extremes', () async {
    await send('GET', '/v1/sessions/s1/messages?limit=9999&offset=-3');
    expect(capturedLimit, '200');
    expect(capturedOffset, '0');
  });

  test('GET messages rejects invalid session id', () async {
    final encoded = Uri.encodeComponent('../other/messages');
    final result = await send('GET', '/v1/sessions/$encoded/messages');
    expect(result['status'], 400);
    expect(result['body']['error'], 'invalid session id');
  });

  test('GET messages returns 501 when history is not configured', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    try {
      final client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/sessions/s1/messages');
      final request = await client.getUrl(uri);
      request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final response = await request.close();
      expect(response.statusCode, 501);
      client.close(force: true);
    } finally {
      await bare.stop();
    }
  });

  test('DELETE /v1/sessions/<id> deletes via callback', () async {
    final result = await send('DELETE', '/v1/sessions/s1');
    expect(result['status'], 200);
    expect(result['body']['deleted'], isTrue);
    expect(deletedId, 's1');
  });

  test('PATCH /v1/sessions/<id> renames via callback', () async {
    final result = await send('PATCH', '/v1/sessions/s1', body: {'title': 'Rencana liburan'});
    expect(result['status'], 200);
    expect(result['body']['ok'], isTrue);
    expect(renamedId, 's1');
    expect(renamedTitle, 'Rencana liburan');
  });

  test('PATCH rename unknown session returns 404', () async {
    final result = await send('PATCH', '/v1/sessions/ghost', body: {'title': 'x'});
    expect(result['status'], 404);
    expect(result['body']['ok'], isFalse);
  });

  test('session endpoints require auth', () async {
    final messages = await send('GET', '/v1/sessions/s1/messages', auth: false);
    expect(messages['status'], 401);
    final deleted = await send('DELETE', '/v1/sessions/s1', auth: false);
    expect(deleted['status'], 401);
    final renamed = await send('PATCH', '/v1/sessions/s1', body: {'title': 'x'}, auth: false);
    expect(renamed['status'], 401);
  });
}
