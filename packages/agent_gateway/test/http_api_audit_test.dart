import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-11: audit query browser — GET /v1/audit dengan filter query
/// string (tool/session/risk/verdict/taint/since/until/limit/offset),
/// validasi 400, dan 501 bare daemon.
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;
  late List<Map<String, dynamic>> lastFilters;

  setUp(() async {
    lastFilters = [];
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      auditQueryProvider: (filters) async {
        lastFilters = [filters];
        return {
          'entries': [
            {
              'ts': '2026-11-18T13:00:00.000Z',
              'session': 'web:default',
              'tool': 'shell.exec',
              'args': {'cmd': 'ls'},
              'risk': 'high',
              'verdict': 'approve',
              'result': 'ok',
              'duration_ms': 42,
              'error': null,
              'taint': false,
            },
          ],
          'total': 1,
        };
      },
    );
    await server.start();
    bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
  });

  tearDown(() async {
    await server.stop();
    await bare.stop();
  });

  Future<Map<String, dynamic>> send(String method, String path,
      HttpApiServer target) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${target.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>,
      };
    } finally {
      client.close(force: true);
    }
  }

  test('GET /v1/audit tanpa filter mengembalikan entries + total', () async {
    final r = await send('GET', '/v1/audit', server);
    expect(r['status'], 200);
    expect(r['body']['total'], 1);
    expect((r['body']['entries'] as List).first['tool'], 'shell.exec');
    expect(lastFilters.single, isEmpty);
  });

  test('filter query string dinormalisasi jadi typed map', () async {
    final r = await send(
      'GET',
      '/v1/audit?tool=shell&risk=High&taint=true'
      '&since=2026-11-18T00%3A00%3A00Z&limit=10&offset=5',
      server,
    );
    expect(r['status'], 200);
    final f = lastFilters.single;
    expect(f['tool'], 'shell');
    expect(f['risk'], 'High');
    expect(f['taint'], isTrue);
    expect((f['since'] as DateTime).isUtc, isTrue);
    expect(f['limit'], 10);
    expect(f['offset'], 5);
  });

  test('filter invalid ditolak 400 invalid_request', () async {
    expect((await send('GET', '/v1/audit?limit=999', server))['status'], 400);
    expect((await send('GET', '/v1/audit?offset=-1', server))['status'], 400);
    expect((await send('GET', '/v1/audit?taint=maybe', server))['status'], 400);
    expect(
        (await send('GET', '/v1/audit?since=bukan-tanggal', server))['status'],
        400);
    expect(lastFilters, isEmpty);
  });

  test('401 tanpa auth + 501 daemon bare + POST 404 read-only', () async {
    final client = HttpClient();
    final uri = Uri.parse(
        'http://127.0.0.1:${server.boundPort}/v1/audit');
    final request = await client.openUrl('GET', uri);
    final response = await request.close();
    expect(response.statusCode, 401);
    client.close(force: true);

    expect((await send('GET', '/v1/audit', bare))['status'], 501);
    expect((await send('POST', '/v1/audit', server))['status'], 404);
  });
}
