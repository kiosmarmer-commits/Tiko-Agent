import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Mission Control (swarm mode) \u2014 endpoint REST live run tim:
/// `GET /v1/teams/runs/live` (501 bila handler null) dan
/// `POST /v1/teams/runs/cancel` (400 tanpa run_id, 404 run tak dikenal).
void main() {
  late HttpApiServer server;
  late List<Map<String, dynamic>> live;
  late Set<String> cancelled;

  setUp(() async {
    live = [];
    cancelled = {};
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      teamLiveProvider: () async => List.of(live),
      cancelTeamRun: (runId) async {
        final found = live.any((r) => r['run_id'] == runId);
        if (!found) return false;
        cancelled.add(runId);
        live.removeWhere((r) => r['run_id'] == runId);
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

  test('GET /v1/teams/runs/live mengembalikan daftar run live', () async {
    live.add({
      'run_id': 'r1',
      'team_id': 'paket-ui',
      'goal': 'buat UI',
      'status': 'running',
      'nodes': <Object>[],
    });
    final r = await send('GET', '/v1/teams/runs/live');
    expect(r['status'], 200);
    expect((r['body']['runs'] as List).first['run_id'], 'r1');
  });

  test('GET /v1/teams/runs/live tanpa handler 501 not_implemented', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/teams/runs/live'),
      );
      req.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(res.statusCode, 501);
      expect(body['code'], 'not_implemented');
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });

  test('POST /v1/teams/runs/cancel membatalkan run aktif', () async {
    live.add({'run_id': 'r1', 'status': 'running'});
    final r = await send('POST', '/v1/teams/runs/cancel', body: {
      'run_id': 'r1',
    });
    expect(r['status'], 200);
    expect(r['body']['cancel_requested'], isTrue);
    expect(cancelled, contains('r1'));
  });

  test('POST /v1/teams/runs/cancel tanpa run_id 400', () async {
    final r = await send('POST', '/v1/teams/runs/cancel', body: {});
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('POST /v1/teams/runs/cancel run tak dikenal 404', () async {
    final r = await send('POST', '/v1/teams/runs/cancel', body: {
      'run_id': 'tidak-ada',
    });
    expect(r['status'], 404);
    expect(r['body']['code'], 'not_found');
  });

  test('GET /v1/teams/runs/live tanpa auth 401', () async {
    final r = await send('GET', '/v1/teams/runs/live', auth: false);
    expect(r['status'], 401);
  });
}
