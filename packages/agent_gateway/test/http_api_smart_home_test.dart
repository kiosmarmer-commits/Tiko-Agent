import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// F6 (docs/15 §7) — smart-home user-facing REST di atas callback wiring
/// provider smart-home: status provider, list/get perangkat, execute.
void main() {
  late HttpApiServer server;
  late bool executeAllowed;
  final executed = <({String provider, String id, Map<String, dynamic> cmd})>[];

  setUp(() async {
    executed.clear();
    executeAllowed = true;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      smartHomeProviders: () async => ['home_assistant', 'tuya'],
      smartHomeDevices: (provider) async {
        if (provider != null && provider != 'home_assistant' && provider != 'tuya') {
          return const [];
        }
        return [
          {
            'id': 'light.kitchen',
            'name': 'Lampu Dapur',
            'provider': provider ?? 'home_assistant',
            'online': true,
            'capabilities': ['on_off'],
            'state': {'state': 'on'},
            'meta': <String, dynamic>{},
          },
        ];
      },
      smartHomeDevice: (provider, deviceId) async {
        if (provider != 'home_assistant' || deviceId != 'light.kitchen') {
          return null;
        }
        return {
          'id': deviceId,
          'name': 'Lampu Dapur',
          'provider': provider,
          'capabilities': <String>[],
          'state': <String, dynamic>{'state': 'on'},
          'meta': <String, dynamic>{},
        };
      },
      smartHomeExecute: (provider, deviceId, command) async {
        if (provider != 'home_assistant' && provider != 'tuya') {
          throw ApiRequestException(404, 'not_found', 'provider tidak dikenal: $provider');
        }
        if (!executeAllowed) {
          throw StateError('perangkat offline');
        }
        executed.add((provider: provider, id: deviceId, cmd: command));
        return {'ok': true, 'provider': provider, 'device_id': deviceId};
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
      if (auth) {
        request.headers.set(
          'authorization',
          'Bearer manager-token-0123456789abcdef',
        );
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
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

  test('GET /v1/smart-home: daftar provider + auth wajib', () async {
    final unauth = await send('GET', '/v1/smart-home', auth: false);
    expect(unauth['status'], 401);

    final r = await send('GET', '/v1/smart-home');
    expect(r['status'], 200);
    expect(r['body']['providers'], ['home_assistant', 'tuya']);
  });

  test('GET /v1/smart-home/devices: semua + filter provider', () async {
    final all = await send('GET', '/v1/smart-home/devices');
    expect(all['status'], 200);
    expect((all['body']['devices'] as List).length, 1);

    final filtered = await send(
      'GET',
      '/v1/smart-home/devices?provider=tuya',
    );
    expect(filtered['status'], 200);
    expect((filtered['body']['devices'] as List).first['provider'], 'tuya');
  });

  test('GET device by provider+id; provider tak dikenal -> 404', () async {
    final ok = await send(
      'GET',
      '/v1/smart-home/devices/home_assistant/light.kitchen',
    );
    expect(ok['status'], 200);
    expect(ok['body']['id'], 'light.kitchen');

    final missing = await send('GET', '/v1/smart-home/devices/unknown/d1');
    expect(missing['status'], 404);
  });

  test('POST execute: command dikirim + validasi payload', () async {
    final ok = await send(
      'POST',
      '/v1/smart-home/devices/home_assistant/light.kitchen/execute',
      body: {'service': 'light.turn_on', 'data': {'brightness': 128}},
    );
    expect(ok['status'], 200);
    expect(ok['body']['ok'], true);
    expect(executed.single.id, 'light.kitchen');
    expect(executed.single.cmd['service'], 'light.turn_on');

    final bad = await send(
      'POST',
      '/v1/smart-home/devices/home_assistant/light.kitchen/execute',
      body: <String, dynamic>{},
    );
    expect(bad['status'], 400);

    final missingProvider = await send(
      'POST',
      '/v1/smart-home/devices/unknown/d1/execute',
      body: {'service': 'light.turn_on'},
    );
    expect(missingProvider['status'], 404);
  });

  test('executor gagal upstream -> 502 retryable', () async {
    executeAllowed = false;
    final r = await send(
      'POST',
      '/v1/smart-home/devices/home_assistant/light.kitchen/execute',
      body: {'service': 'light.turn_on'},
    );
    expect(r['status'], 502);
    expect(r['body']['retryable'], true);
  });
}
