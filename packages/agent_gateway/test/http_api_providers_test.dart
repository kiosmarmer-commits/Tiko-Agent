import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-05: provider & model manager — GET /v1/providers dan
/// POST /v1/providers/session di atas callbacks wiring.
void main() {
  late HttpApiServer server;
  late Map<String, String> overrides;
  String? lastModel;

  Map<String, dynamic> snapshot() => {
        'default': 'mock-1',
        'providers': [
          {
            'id': 'mock-1',
            'capabilities': {
              'tool_calling': true,
              'vision': false,
              'streaming': true,
              'max_context': 8192,
            },
            'health': {
              'failures': 0,
              'successes': 9,
              'open': false,
              'phase': 'closed',
              'last_error': null,
              'last_latency_ms': 12.5,
            },
          },
          {
            'id': 'mock-2',
            'capabilities': null,
            'health': null,
          },
        ],
        'tiers': {'1': 'mock-1', '3': 'mock-2'},
        'session_overrides': overrides,
      };

  setUp(() async {
    overrides = {'ws:lab': 'mock-2'};
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      providersProvider: () async => snapshot(),
      providerModels: (providerId) async {
        if (providerId != 'mock-1') {
          throw StateError('provider tidak dikenal: $providerId');
        }
        return {
          'provider': providerId,
          'models': <String>['mock-1-base', 'mock-1-turbo'],
          'count': 2,
          'discovered': true,
        };
      },
      sessionProviderSetter: (sessionId, arg, model) async {
        if (arg.toLowerCase() == 'default') {
          overrides.remove(sessionId);
          lastModel = null;
          return true;
        }
        if (arg != 'mock-1' && arg != 'mock-2') return false;
        overrides[sessionId] = arg.toLowerCase();
        lastModel = model;
        return true;
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

  test('GET /v1/providers mengembalikan snapshot lengkap', () async {
    final r = await send('GET', '/v1/providers');
    expect(r['status'], 200);
    expect(r['body']['default'], 'mock-1');
    final providers = r['body']['providers'] as List;
    expect(providers.length, 2);
    expect(providers[0]['id'], 'mock-1');
    expect(providers[0]['health']['phase'], 'closed');
    expect(r['body']['tiers'], {'1': 'mock-1', '3': 'mock-2'});
    expect(r['body']['session_overrides'], {'ws:lab': 'mock-2'});
  });

  test('GET /v1/providers tanpa auth 401', () async {
    final r = await send('GET', '/v1/providers', auth: false);
    expect(r['status'], 401);
  });

  test('POST /v1/providers/session memasang override', () async {
    final r = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:baru',
      'provider': 'mock-1',
    });
    expect(r['status'], 200);
    expect(r['body']['ok'], isTrue);
    expect(r['body']['provider'], 'mock-1');
  });

  test('POST /v1/providers/session dengan model opsional diteruskan', () async {
    final r = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:baru',
      'provider': 'mock-1',
      'model': 'mock-1-turbo',
    });
    expect(r['status'], 200);
    expect(r['body']['model'], 'mock-1-turbo');
    expect(lastModel, 'mock-1-turbo');
  });

  test('POST /v1/providers/session tanpa model → null diteruskan', () async {
    await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:baru',
      'provider': 'mock-1',
    });
    expect(lastModel, isNull);
  });

  test('POST model non-string ditolak 400', () async {
    final r = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:baru',
      'provider': 'mock-1',
      'model': 42,
    });
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('GET /v1/providers/<id>/models live discovery', () async {
    final r = await send('GET', '/v1/providers/mock-1/models');
    expect(r['status'], 200);
    expect(r['body']['provider'], 'mock-1');
    expect(r['body']['models'], containsAll(['mock-1-base', 'mock-1-turbo']));
    expect(r['body']['count'], 2);
  });

  test('GET /v1/providers/<id>/models unknown → 404', () async {
    final r = await send('GET', '/v1/providers/grid-9/models');
    expect(r['status'], 404);
    expect(r['body']['code'], 'not_found');
  });

  test('GET /v1/providers/<id>/models tanpa callback → 501', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'http://127.0.0.1:${bare.boundPort}/v1/providers/mock-1/models',
      );
      final request = await client.getUrl(uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final body = jsonDecode(text) as Map<String, dynamic>;
      expect(response.statusCode, 501);
      expect(body['code'], 'not_implemented');
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });

  test("POST provider 'default' melepas override", () async {
    final r = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:lab',
      'provider': 'default',
    });
    expect(r['status'], 200);
    expect(overrides.containsKey('ws:lab'), isFalse);
  });

  test('POST provider tidak dikenal 404', () async {
    final r = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:lab',
      'provider': 'grid-9',
    });
    expect(r['status'], 404);
    expect(r['body']['code'], 'not_found');
  });

  test('POST tanpa session_id atau provider 400', () async {
    final r1 = await send('POST', '/v1/providers/session', body: {
      'provider': 'mock-1',
    });
    expect(r1['status'], 400);

    final r2 = await send('POST', '/v1/providers/session', body: {
      'session_id': 'ws:lab',
    });
    expect(r2['status'], 400);
    expect(r2['body']['code'], 'invalid_request');
  });

  test('daemon tanpa callback 501 not_implemented', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/providers');
      final request = await client.getUrl(uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      expect(response.statusCode, 501);
      expect(body['code'], 'not_implemented');
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });
}
