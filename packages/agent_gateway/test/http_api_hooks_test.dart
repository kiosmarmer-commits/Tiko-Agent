import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// SETTINGS-HOOKS: GET /v1/hooks, POST /v1/hooks, PATCH+DELETE
/// `/v1/hooks/<n>`, dan POST `/v1/hooks/test` di atas callbacks wiring.
void main() {
  late HttpApiServer server;
  late Map<String, dynamic> snapshot;
  late Map<String, dynamic>? lastAdded;
  late int? lastUpdatedIndex;
  late int? lastDeletedIndex;
  late int? lastTestedIndex;

  setUp(() async {
    snapshot = {
      'rules': [
        {
          'event': 'model.switched',
          'webhook': 'https://hook.example/induk',
          'timeout_sec': 10,
          'env': {'WHO': 'tiko'},
        },
        {
          'event': '*',
          'script': 'scripts/on_event.sh',
          'timeout_sec': 30,
          'env': <String, dynamic>{},
        },
      ],
      'stats': {
        'hooks[0]:webhook': {
          'fires': 3,
          'failures': 1,
          'last_error': 'webhook merespons 500',
          'last_at': '2026-11-24T00:00:00.000Z',
        },
      },
    };
    lastAdded = null;
    lastUpdatedIndex = null;
    lastDeletedIndex = null;
    lastTestedIndex = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      hooksSnapshotProvider: () async => snapshot,
      hookAddProvider: (body) async {
        lastAdded = body;
        return {'ok': true, 'rules': snapshot['rules']};
      },
      hookUpdateProvider: (index, body) async {
        lastUpdatedIndex = index;
        lastAdded = body;
        return {'ok': true, 'rules': snapshot['rules']};
      },
      hookDeleteProvider: (index) async {
        lastDeletedIndex = index;
        return {'ok': true, 'rules': snapshot['rules']};
      },
      hookTestProvider: (index) async {
        lastTestedIndex = index;
        return {
          'ok': true,
          'index': index,
          'results': [
            {'target': 'webhook', 'ok': true},
          ],
        };
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
      if (auth) {
        request.headers.set(
          'authorization',
          'Bearer manager-token-0123456789abcdef',
        );
      }
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
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

  test('GET /v1/hooks mengembalikan rules + stats', () async {
    final r = await send('GET', '/v1/hooks');
    expect(r['status'], 200);
    expect((r['body']['rules'] as List).length, 2);
    expect(
      ((r['body']['stats'] as Map).values.first)['fires'],
      3,
    );
  });

  test('POST /v1/hooks meneruskan aturan tervalidasi', () async {
    final r = await send('POST', '/v1/hooks', body: {
      'event': 'approval.denied',
      'webhook': 'https://hook.example/alert',
      'timeout_sec': 15,
    });
    expect(r['status'], 200);
    expect(r['body']['ok'], isTrue);
    expect(lastAdded?['event'], 'approval.denied');
    expect(lastAdded?['timeout_sec'], 15);
  });

  test('POST /v1/hooks menolak body non-mapping', () async {
    final r = await send('POST', '/v1/hooks', body: ['bukan', 'mapping']);
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('PATCH /v1/hooks/0 meneruskan indeks + aturan', () async {
    final r = await send('PATCH', '/v1/hooks/0', body: {
      'event': '*',
      'script': 'scripts/on_event.sh',
    });
    expect(r['status'], 200);
    expect(lastUpdatedIndex, 0);
    expect(lastAdded?['script'], 'scripts/on_event.sh');
  });

  test('DELETE /v1/hooks/1 meneruskan indeks', () async {
    final r = await send('DELETE', '/v1/hooks/1');
    expect(r['status'], 200);
    expect(lastDeletedIndex, 1);
  });

  test('POST /v1/hooks/test menolak index non-integer', () async {
    final r = await send('POST', '/v1/hooks/test', body: {'index': '0'});
    expect(r['status'], 400);
    expect(lastTestedIndex, isNull);
  });

  test('POST /v1/hooks/test meneruskan index integer', () async {
    final r = await send('POST', '/v1/hooks/test', body: {'index': 0});
    expect(r['status'], 200);
    expect(lastTestedIndex, 0);
    expect(((r['body']['results'] as List).first)['ok'], isTrue);
  });

  test('tanpa auth ditolak 401', () async {
    final r = await send('GET', '/v1/hooks', auth: false);
    expect(r['status'], 401);
  });
}
