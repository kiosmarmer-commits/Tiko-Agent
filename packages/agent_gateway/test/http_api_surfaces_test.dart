import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {});

  Future<(HttpApiServer, Map<String, String>)> start({
    Future<List<Map<String, dynamic>>> Function(String?)? surfacesProvider,
    Future<Map<String, dynamic>?> Function(String)? surfaceGetter,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? surfaceCreator,
    Future<bool> Function(String)? surfaceDeleter,
  }) async {
    final server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      surfacesProvider: surfacesProvider,
      surfaceGetter: surfaceGetter,
      surfaceCreator: surfaceCreator,
      surfaceDeleter: surfaceDeleter,
    );
    await server.start();
    return (
      server,
      {
        'authorization': 'Bearer manager-token-0123456789abcdef',
        'content-type': 'application/json',
      }
    );
  }

  Future<Map<String, dynamic>> request(
    HttpApiServer server,
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final req = await client.openUrl(method, uri);
      headers?.forEach(req.headers.set);
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return {'status': res.statusCode, 'body': jsonDecode(text)};
    } finally {
      client.close(force: true);
    }
  }

  tearDown(() async {});

  test('GET /v1/surfaces 501 bila provider belum dikonfigurasi', () async {
    final (server, headers) = await start();
    final res = await request(server, 'GET', '/v1/surfaces', headers: headers);
    expect(res['status'], 501);
    await server.stop();
  });

  test('GET /v1/surfaces mengembalikan daftar + filter session_key',
      () async {
    final (server, headers) = await start(
      surfacesProvider: (sessionKey) async => [
        {'surfaceId': 's-ui-1', 'sessionKey': 'web:abc'},
      ],
    );
    final res =
        await request(server, 'GET', '/v1/surfaces?session_key=web%3Aabc',
            headers: headers);
    expect(res['status'], 200);
    expect((res['body']['surfaces'] as List), hasLength(1));
    await server.stop();
  });

  test('GET /v1/surfaces/<id> 200 dan 404', () async {
    final (server, headers) = await start(
      surfaceGetter: (id) async =>
          id == 's-ui-1' ? {'surfaceId': 's-ui-1'} : null,
    );
    final ok =
        await request(server, 'GET', '/v1/surfaces/s-ui-1', headers: headers);
    expect(ok['status'], 200);
    expect(ok['body']['surfaceId'], 's-ui-1');
    final missing =
        await request(server, 'GET', '/v1/surfaces/s-x', headers: headers);
    expect(missing['status'], 404);
    await server.stop();
  });

  test('GET /v1/surfaces/<id> menolak id tidak aman (path traversal)', () async {
    final (server, headers) = await start(
      surfaceGetter: (id) async => {'surfaceId': id},
    );
    final res = await request(
        server, 'GET', '/v1/surfaces/..%2Fetc%2Fpasswd',
        headers: headers);
    expect(res['status'], 400);
    await server.stop();
  });

  test('DELETE /v1/surfaces/<id> 200/404', () async {
    final (server, headers) = await start(
      surfaceDeleter: (id) async => id == 's-ui-1',
    );
    final ok = await request(server, 'DELETE', '/v1/surfaces/s-ui-1',
        headers: headers);
    expect(ok['status'], 200);
    expect(ok['body']['ok'], isTrue);
    final missing = await request(
        server, 'DELETE', '/v1/surfaces/s-x',
        headers: headers);
    expect(missing['status'], 404);
    await server.stop();
  });

  test('POST /v1/surfaces 501 bila host belum menyediakan creator', () async {
    final (server, headers) = await start();
    final res = await request(server, 'POST', '/v1/surfaces',
        headers: headers, body: {'surfaceId': 's-ui-1'});
    expect(res['status'], 501);
    await server.stop();
  });

  test('endpoint surfaces memerlukan auth', () async {
    final (server, _) = await start(
      surfacesProvider: (_) async => [],
    );
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('http://127.0.0.1:${server.boundPort}/v1/surfaces');
      final req = await client.openUrl('GET', uri);
      final res = await req.close();
      expect(res.statusCode, 401);
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });
}
