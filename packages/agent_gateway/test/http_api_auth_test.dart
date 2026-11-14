import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late HttpClient client;
  late StreamController<Map<String, dynamic>> events;

  setUp(() async {
    events = StreamController<Map<String, dynamic>>.broadcast();
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'test-secret',
      port: 0,
      eventStream: events.stream,
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await events.close();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
    final req = await client.openUrl(method, uri);
    headers.forEach(req.headers.set);
    return req.close();
  }

  test('token via query ?token= ditolak', () async {
    final res = await send(
      'GET',
      '/v1/status?token=test-secret',
    );
    expect(res.statusCode, 401);
  });

  test('Bearer token benar diterima', () async {
    final res = await send(
      'GET',
      '/v1/status',
      headers: {HttpHeaders.authorizationHeader: 'Bearer test-secret'},
    );
    expect(res.statusCode, 200);
  });

  test('Host asing ditolak 421', () async {
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/v1/status');
    final req = await client.openUrl('GET', uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-secret');
    req.headers.set(HttpHeaders.hostHeader, 'evil.example');
    final res = await req.close();
    expect(res.statusCode, 421);
  });

  test('ticket sekali pakai: valid sekali, replay ditolak', () async {
    final ticketRes = await send(
      'POST',
      '/v1/auth/ticket',
      headers: {HttpHeaders.authorizationHeader: 'Bearer test-secret'},
    );
    expect(ticketRes.statusCode, 200);
    final body =
        jsonDecode(await ticketRes.transform(utf8.decoder).join()) as Map;
    final ticket = body['ticket'] as String;
    expect(ticket, isNotEmpty);

    final wsUrl = Uri.parse(
      'ws://127.0.0.1:${server.boundPort}/v1/stream?ticket=$ticket',
    );
    final first = await WebSocket.connect(wsUrl.toString());
    await first.close();
    expect(first.closeCode, isNull);

    Object? replayError;
    try {
      final ws = await WebSocket.connect(wsUrl.toString());
      await ws.close();
      fail('replay ticket harusnya ditolak');
    } catch (e) {
      replayError = e;
    }
    expect(replayError, isNotNull);
  });

  test('ticket tanpa auth endpoint tidak diterima', () async {
    final res = await send('POST', '/v1/auth/ticket');
    expect(res.statusCode, 401);
  });
}
