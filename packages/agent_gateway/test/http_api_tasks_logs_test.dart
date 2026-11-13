import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      tasksProvider: () async => [
        {
          'id': 'kb-1',
          'title': 'rapikan README',
          'state': 'done',
          'created_by': 'web',
          'claimed_by': 'agent',
          'updated_at': '2026-11-13T00:00:00.000Z',
          'result': 'selesai',
        },
        {
          'id': 'kb-2',
          'title': 'kirim laporan',
          'state': 'backlog',
          'created_by': 'tg',
          'claimed_by': '',
          'updated_at': '2026-11-13T01:00:00.000Z',
          'result': '',
        },
      ],
      logsProvider: () async => [
        {'name': 'audit-20261113.jsonl', 'bytes': 128},
        {'name': 'audit-20261112.jsonl', 'bytes': 64},
      ],
      logContentProvider: (name) async => name == 'audit-20261113.jsonl'
          ? {
              'name': name,
              'bytes': 128,
              'truncated': false,
              'content': '{"tool":"shell"}\n',
            }
          : null,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> getJson(
    String path, {
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.getUrl(uri);
      if (auth) request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return {'status': response.statusCode, 'body': jsonDecode(body) as Map<String, dynamic>};
    } finally {
      client.close(force: true);
    }
  }

  test('GET /v1/tasks returns kanban tasks from the provider', () async {
    final result = await getJson('/v1/tasks');
    expect(result['status'], 200);
    expect((result['body']['tasks'] as List).length, 2);
    expect(result['body']['tasks'][0]['title'], 'rapikan README');
    expect(result['body']['tasks'][0]['state'], 'done');
  });

  test('GET /v1/tasks requires auth', () async {
    final result = await getJson('/v1/tasks', auth: false);
    expect(result['status'], 401);
  });

  test('GET /v1/logs lists audit files', () async {
    final result = await getJson('/v1/logs');
    expect(result['status'], 200);
    expect((result['body']['logs'] as List).length, 2);
    expect(result['body']['logs'][0]['name'], 'audit-20261113.jsonl');
  });

  test('GET /v1/logs/<name> returns capped content', () async {
    final result = await getJson('/v1/logs/audit-20261113.jsonl');
    expect(result['status'], 200);
    expect(result['body']['truncated'], isFalse);
    expect(result['body']['content'], contains('shell'));
  });

  test('GET /v1/logs/<unknown> returns 404', () async {
    final result = await getJson('/v1/logs/audit-19990101.jsonl');
    expect(result['status'], 404);
  });

  test('GET /v1/logs rejects path traversal names', () async {
    final encoded = Uri.encodeComponent('../secrets.jsonl');
    final result = await getJson('/v1/logs/$encoded');
    expect(result['status'], 400);
    expect(result['body']['error'], 'invalid log name');
  });

  test('GET /v1/logs rejects slash-bearing names without calling provider', () async {
    final result = await getJson('/v1/logs/audit-20261113.jsonl/extra');
    expect(result['status'], 400);
  });
}
