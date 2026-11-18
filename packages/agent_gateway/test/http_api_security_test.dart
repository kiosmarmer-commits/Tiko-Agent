import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-10: Security Center — GET /v1/security read-only di atas
/// callback wiring runtime (safe mode, sandbox, credential state,
/// consent plugin, token anomaly, guard, audit ringkas).
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      securityProvider: () async => {
        'safety': {'safe_mode': true, 'panic': false, 'stop_requested': false},
        'sandbox': 'none',
        'credentials': {'sealed_storage': false},
        'plugins': [
          {'id': 'echo', 'registered': true, 'pending': false, 'granted_count': 1, 'requested_count': 2},
        ],
        'token_anomaly': {
          'enabled': true,
          'quarantines_today': 1,
          'max_quarantines_per_day': 3,
          'skills': [{'slug': 'demo', 'samples': 5, 'mean': 100.0, 'stddev': 10.0, 'last': 320}],
        },
        'rate_anomaly': {'window_sec': 60, 'max_events': 30},
        'guard': {'blocked_turns': 2, 'sanitized_turns': 7},
        'audit': {
          'total_in_memory': 1,
          'recent': [
            {'ts': '2026-11-18T13:00:00.000Z', 'tool': 'shell', 'risk': 'high', 'verdict': 'approve', 'session': 'web:default'},
          ],
        },
        'active_sessions': 3,
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

  Future<Map<String, dynamic>> send(String method, String path, HttpApiServer target) async {
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

  test('GET /v1/security mengembalikan snapshot konsolidasi', () async {
    final r = await send('GET', '/v1/security', server);
    expect(r['status'], 200);
    expect(r['body']['safety']['safe_mode'], isTrue);
    expect(r['body']['sandbox'], 'none');
    expect(r['body']['credentials']['sealed_storage'], isFalse);
    expect((r['body']['plugins'] as List).first['granted_count'], 1);
    expect(r['body']['token_anomaly']['enabled'], isTrue);
    expect(r['body']['token_anomaly']['quarantines_today'], 1);
    expect((r['body']['token_anomaly']['skills'] as List).first['slug'], 'demo');
    expect(r['body']['guard']['blocked_turns'], 2);
    expect(r['body']['rate_anomaly']['max_events'], 30);
    expect(r['body']['active_sessions'], 3);
    final recent = (r['body']['audit']['recent'] as List).first;
    expect(recent['tool'], 'shell');
    expect(recent['risk'], 'high');
  });

  test('GET /v1/security tanpa auth 401', () async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/v1/security');
      final request = await client.getUrl(uri);
      final response = await request.close();
      expect(response.statusCode, 401);
    } finally {
      client.close(force: true);
    }
  });

  test('daemon tanpa callback 501 not_implemented', () async {
    final r = await send('GET', '/v1/security', bare);
    expect(r['status'], 501);
    expect(r['body']['code'], 'not_implemented');
  });

  test('POST /v1/security 404 (read-only, tanpa mutasi)', () async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/v1/security');
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
}
