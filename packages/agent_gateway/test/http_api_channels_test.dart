import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-07: channels setup — GET /v1/channels di atas callback wiring
/// (read-only: status channel + nama env, tanpa nilai rahasia).
void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      channelsProvider: () async => {
        'channels': [
          {
            'channel': 'telegram',
            'active': true,
            'env': ['TG_TOKEN', 'TG_ALLOW'],
          },
          {
            'channel': 'discord',
            'active': false,
            'env': ['DISCORD_BOT_TOKEN', 'DISCORD_ALLOW'],
          },
          {
            'channel': 'http',
            'active': true,
            'env': <String>[],
          },
        ],
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
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl(method, uri);
      if (auth) {
        request.headers.set(
          'authorization',
          'Bearer manager-token-0123456789abcdef',
        );
      }
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

  test('GET /v1/channels mengembalikan snapshot channel + nama env',
      () async {
    final r = await send('GET', '/v1/channels');
    expect(r['status'], 200);
    final channels = r['body']['channels'] as List;
    expect(channels.length, 3);
    expect(channels[0]['channel'], 'telegram');
    expect(channels[0]['active'], isTrue);
    expect(channels[0]['env'], ['TG_TOKEN', 'TG_ALLOW']);
    expect(channels[1]['active'], isFalse);
    expect(channels[2]['env'], isEmpty);
  });

  test('GET /v1/channels tanpa auth 401', () async {
    final r = await send('GET', '/v1/channels', auth: false);
    expect(r['status'], 401);
  });

  test('POST /v1/channels 404 (read-only, tanpa mutasi)', () async {
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('http://127.0.0.1:${server.boundPort}/v1/channels');
      final request = await client.postUrl(uri);
      request.headers.set(
        'authorization',
        'Bearer manager-token-0123456789abcdef',
      );
      final response = await request.close();
      expect(response.statusCode, 404);
    } finally {
      client.close(force: true);
    }
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
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/channels');
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
