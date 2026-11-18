import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-06: plugin & tools manager — GET /v1/plugins dan
/// POST /v1/plugins/consent di atas callbacks wiring.
void main() {
  late HttpApiServer server;
  late List<Map<String, dynamic>> snapshotPlugins;
  late Map<String, String> consents;

  setUp(() async {
    snapshotPlugins = [
      {
        'id': 'memory-secretary',
        'registered': true,
        'pending': false,
        'granted': ['memory.write'],
        'requested': <String>[],
      },
      {
        'id': 'weather-pro',
        'registered': false,
        'pending': true,
        'granted': <String>[],
        'requested': ['tools.register', 'network.fetch'],
      },
    ];
    consents = {'memory-secretary': 'memory.write'};
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      pluginProvider: () async => {
        'plugins': snapshotPlugins,
        'events': [
          {
            'plugin': 'weather-pro',
            'hook': 'onSessionStart',
            'detail': 'consent required',
            'error': null,
            'at': '2026-11-18T00:00:00.000Z',
          },
        ],
        'tools': [
          {
            'name': 'read_file',
            'description': 'Baca file',
            'risk': 'low',
            'timeout_sec': 30,
            'parallel_safe': true,
          },
          {
            'name': 'shell_exec',
            'description': 'Eksekusi shell',
            'risk': 'critical',
            'timeout_sec': 60,
            'parallel_safe': false,
          },
        ],
        'mcp': {
          'started': true,
          'configured': [
            {
              'id': 'fs-mcp',
              'type': 'stdio',
              'enabled': true,
              'risk': 'medium',
              'command': '/usr/bin/fs-mcp',
              'allow': <String>[],
            },
          ],
          'loader': [
            {'id': 'fs-mcp', 'status': 'ready', 'transport': 'stdio', 'tools': 2},
          ],
        },
      },
      pluginConsentSetter: (plugin, action) async {
        if (plugin != 'weather-pro' && plugin != 'memory-secretary') {
          return {
            'ok': false,
            'message': 'Plugin "$plugin" tidak dikenal.',
          };
        }
        if (action == 'grant') {
          if (plugin != 'weather-pro') {
            return {
              'ok': false,
              'message': 'Plugin "$plugin" tidak menunggu consent.',
            };
          }
          consents[plugin] = 'tools.register,network.fetch';
          return {
            'ok': true,
            'message': 'Plugin "$plugin" disetujui dan terdaftar '
                '(tools.register, network.fetch).',
          };
        }
        consents.remove(plugin);
        return {'ok': true, 'message': 'Consent plugin "$plugin" dicabut.'};
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

  test('GET /v1/plugins mengembalikan snapshot plugin + tools + mcp',
      () async {
    final r = await send('GET', '/v1/plugins');
    expect(r['status'], 200);
    final plugins = r['body']['plugins'] as List;
    expect(plugins.length, 2);
    expect(plugins[0]['id'], 'memory-secretary');
    expect(plugins[0]['registered'], isTrue);
    expect(plugins[1]['pending'], isTrue);
    expect(plugins[1]['requested'], ['tools.register', 'network.fetch']);
    final tools = r['body']['tools'] as List;
    expect(tools.length, 2);
    expect(tools[0]['name'], 'read_file');
    expect((r['body']['mcp']['loader'] as List).first['status'], 'ready');
    expect((r['body']['events'] as List).first['plugin'], 'weather-pro');
  });

  test('GET /v1/plugins tanpa auth 401', () async {
    final r = await send('GET', '/v1/plugins', auth: false);
    expect(r['status'], 401);
  });

  test('POST /v1/plugins/consent grant plugin pending', () async {
    final r = await send('POST', '/v1/plugins/consent', body: {
      'plugin': 'weather-pro',
      'action': 'grant',
    });
    expect(r['status'], 200);
    expect(r['body']['ok'], isTrue);
    expect(r['body']['message'], contains('weather-pro'));
    expect(consents['weather-pro'], contains('tools.register'));
  });

  test('POST consent revoke plugin terdaftar', () async {
    final r = await send('POST', '/v1/plugins/consent', body: {
      'plugin': 'memory-secretary',
      'action': 'revoke',
    });
    expect(r['status'], 200);
    expect(r['body']['ok'], isTrue);
    expect(consents.containsKey('memory-secretary'), isFalse);
  });

  test('POST consent plugin tidak dikenal 404', () async {
    final r = await send('POST', '/v1/plugins/consent', body: {
      'plugin': 'ghost',
      'action': 'grant',
    });
    expect(r['status'], 404);
    expect(r['body']['code'], 'not_found');
  });

  test('POST consent plugin tanpa pending 404', () async {
    final r = await send('POST', '/v1/plugins/consent', body: {
      'plugin': 'memory-secretary',
      'action': 'grant',
    });
    expect(r['status'], 404);
    expect(r['body']['code'], 'not_found');
  });

  test('POST consent tanpa plugin / action invalid 400', () async {
    final r1 = await send('POST', '/v1/plugins/consent', body: {
      'action': 'grant',
    });
    expect(r1['status'], 400);
    expect(r1['body']['code'], 'invalid_request');

    final r2 = await send('POST', '/v1/plugins/consent', body: {
      'plugin': 'weather-pro',
      'action': 'restart',
    });
    expect(r2['status'], 400);
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
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/plugins');
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
