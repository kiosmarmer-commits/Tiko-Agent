import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P2-04: Run-inspector — GET /v1/runs read-only (snapshot turn aktif +
/// riwayat); 501 bare daemon, method lain 404.
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;
  var calls = 0;

  setUp(() async {
    calls = 0;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      runsProvider: () async {
        calls++;
        return {
          'active': [
            {
              'id': 'run-1',
              'session': 'web:1',
              'channel': 'web',
              'subagent': false,
              'parent': null,
              'input': 'kerjakan laporan',
              'state': 'running',
              'started_at': '2026-11-18T13:00:00.000Z',
              'ended_at': null,
              'duration_ms': null,
              'success': null,
              'tokens_used': 0,
              'tool_calls': 0,
              'answer': null,
              'error': null,
              'steps': [
                {
                  'tool': 'datetime',
                  'verdict': 'allowed',
                  'is_error': false,
                  'duration_ms': 12,
                  'at': '2026-11-18T13:00:01.000Z',
                },
              ],
            },
          ],
          'recent': <Map<String, dynamic>>[],
          'truncated': false,
          'cost': {
            'group_by': 'user',
            'days': 7,
            'window_start': '2026-11-18T00:00:00.000Z',
            'total': {
              'turns': 1,
              'tokens_used': 320,
              'tool_calls': 1,
              'success': 1,
            },
            'buckets': [
              {
                'key': 'local',
                'turns': 1,
                'tokens_used': 320,
                'tool_calls': 1,
                'success': 1,
              },
            ],
          },
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

  test('GET /v1/runs mengembalikan snapshot dan memanggil provider', () async {
    final r = await send('GET', '/v1/runs', server);
    expect(r['status'], 200);
    expect(calls, 1);
    final active = r['body']['active'] as List;
    expect(active, hasLength(1));
    final run = active.first as Map<String, dynamic>;
    expect(run['id'], 'run-1');
    expect(run['state'], 'running');
    expect((run['steps'] as List).first['tool'], 'datetime');
    expect((r['body']['recent'] as List), isEmpty);
    final cost = r['body']['cost'] as Map<String, dynamic>;
    expect(cost['group_by'], 'user');
    expect(cost['days'], 7);
    expect((cost['total'] as Map<String, dynamic>)['tokens_used'], 320);
    expect((cost['buckets'] as List), hasLength(1));
  });

  test('401 tanpa auth + 501 bare + POST 404 read-only', () async {
    final client = HttpClient();
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/v1/runs');
    final request = await client.openUrl('GET', uri);
    final response = await request.close();
    expect(response.statusCode, 401);
    client.close(force: true);

    expect((await send('GET', '/v1/runs', bare))['status'], 501);
    expect((await send('POST', '/v1/runs', server))['status'], 404);
  });
}
