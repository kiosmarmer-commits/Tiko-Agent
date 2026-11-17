import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P0-03: error model typed — setiap error HTTP membawa
/// {ok:false, code, error, retryable} tanpa merusak klien lama.
void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set('content-type', 'application/json');
      if (auth) request.headers.set('authorization', 'Bearer ${server.authToken}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': jsonDecode(body) as Map<String, dynamic>,
      };
    } finally {
      client.close();
    }
  }

  test('401 tanpa token: code unauthorized, retryable false', () async {
    final result = await send('GET', '/v1/sessions', auth: false);
    expect(result['status'], 401);
    expect(result['body']['ok'], false);
    expect(result['body']['code'], 'unauthorized');
    expect(result['body']['error'], 'unauthorized');
    expect(result['body']['retryable'], false);
  });

  test('501 session history belum dikonfigurasi: code not_implemented',
      () async {
    final result = await send('GET', '/v1/sessions/s1/messages');
    expect(result['status'], 501);
    expect(result['body']['code'], 'not_implemented');
    expect(result['body']['error'], 'session history not configured');
  });

  test('501 ui actions belum dikonfigurasi: code not_implemented', () async {
    final result = await send('POST', '/v1/ui/actions', auth: true);
    expect(result['status'], 501);
    expect(result['body']['code'], 'not_implemented');
    expect(result['body']['error'], 'ui actions not configured');
  });

  test('400 session id tidak valid: code invalid_request', () async {
    final result = await send('DELETE', '/v1/sessions/..%2Fetc');
    expect(result['status'], 400);
    expect(result['body']['code'], 'invalid_request');
    expect(result['body']['error'], 'invalid session id');
  });

  test('404 route tidak dikenal: code not_found', () async {
    final result = await send('GET', '/v1/tidak-ada');
    expect(result['status'], 404);
    expect(result['body']['code'], 'not_found');
    expect(result['body']['error'], 'not found');
  });

  test('500 handler melempar: code server, retryable true', () async {
    final failing = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      listSessions: () => throw StateError('boom'),
    );
    await failing.start();
    try {
      final client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:${failing.boundPort}/v1/sessions');
      final request = await client.openUrl('GET', uri);
      request.headers.set('authorization', 'Bearer ${failing.authToken}');
      final response = await request.close();
      final body = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      client.close();
      expect(response.statusCode, 500);
      expect(body['code'], 'server');
      expect(body['retryable'], true);
      expect(body['error'], contains('boom'));
    } finally {
      await failing.stop();
    }
  });
}
