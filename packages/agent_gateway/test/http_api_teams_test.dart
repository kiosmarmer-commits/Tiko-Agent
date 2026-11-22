import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Fase C — endpoint REST `/v1/teams` (list/get/create/update/delete/run +
/// laporan run). Callback menyimulasikan host; kontraknya: 501 bila tidak
/// dikonfigurasi, 400 payload invalid, 404 id tak dikenal.

Map<String, dynamic> _team(String id, {List<Map<String, dynamic>>? members}) =>
    {
      'id': id,
      'name': 'Tim $id',
      'description': '',
      'members': members ??
          [
            {
              'id': 'worker',
              'role': 'custom',
              'system_prompt': 'Kamu worker.',
            },
          ],
    };

void main() {
  late HttpApiServer server;
  late Map<String, Map<String, dynamic>> teams;
  late List<Map<String, dynamic>> runs;

  setUp(() async {
    teams = {'paket-ui': _team('paket-ui')};
    runs = [];
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      teamsProvider: () async =>
          teams.values.map((t) => Map<String, dynamic>.from(t)).toList(),
      getTeam: (id) async =>
          teams[id] == null ? null : Map<String, dynamic>.from(teams[id]!),
      createTeam: (body) async {
        final id = body['id'] as String;
        if (teams.containsKey(id)) {
          throw ApiRequestException(409, 'conflict', 'team "$id" sudah ada');
        }
        teams[id] = _team(id);
        return Map<String, dynamic>.from(teams[id]!);
      },
      updateTeam: (id, body) async {
        final current = teams[id];
        if (current == null) return null;
        final updated = Map<String, dynamic>.from(current);
        if (body.containsKey('name')) updated['name'] = body['name'];
        if (body.containsKey('description')) {
          updated['description'] = body['description'];
        }
        if (body.containsKey('members')) updated['members'] = body['members'];
        teams[id] = updated;
        return Map<String, dynamic>.from(updated);
      },
      deleteTeam: (id) async => teams.remove(id) != null,
      teamRunsProvider: () async => runs,
      teamRunStarter: (body) async {
        final result = {
          'run_id': 't-x',
          'goal': body['goal'],
          'team_id': body['team_id'],
          'success': true,
          'synthesis': 'selesai',
        };
        runs.add(result);
        return result;
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

  test('GET /v1/teams mengembalikan daftar tim', () async {
    final r = await send('GET', '/v1/teams');
    expect(r['status'], 200);
    expect((r['body']['teams'] as List).map((t) => t['id']),
        contains('paket-ui'));
  });

  test('GET /v1/teams tanpa auth 401', () async {
    final r = await send('GET', '/v1/teams', auth: false);
    expect(r['status'], 401);
    expect(r['body']['code'], 'unauthorized');
  });

  test('POST /v1/teams membuat tim (201), duplikat 409', () async {
    final r = await send('POST', '/v1/teams', body: {
      'id': 'riset-daily',
      'name': 'Tim Riset',
      'members': [
        {'id': 'researcher', 'prompt': 'Kamu researcher.'},
      ],
    });
    expect(r['status'], 201);
    expect(r['body']['id'], 'riset-daily');
    final dup = await send('POST', '/v1/teams', body: {
      'id': 'riset-daily',
      'name': 'Dua',
      'members': [
        {'id': 'a', 'prompt': 'p'},
      ],
    });
    expect(dup['status'], 409);
    expect(dup['body']['code'], 'conflict');
  });

  test('POST /v1/teams tanpa members 400', () async {
    final r = await send('POST', '/v1/teams', body: {
      'id': 'salah',
      'name': 'Tanpa Anggota',
    });
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('POST /v1/teams field tak dikenal 400', () async {
    final r = await send('POST', '/v1/teams', body: {
      'id': 'salah',
      'name': 'X',
      'members': [
        {'id': 'a', 'prompt': 'p'},
      ],
      'tool_allowlist': ['x'],
    });
    expect(r['status'], 400);
  });

  test('GET /v1/teams/{id} 200 dan 404', () async {
    final r = await send('GET', '/v1/teams/paket-ui');
    expect(r['status'], 200);
    expect(r['body']['name'], contains('paket-ui'));
    final missing = await send('GET', '/v1/teams/hantu');
    expect(missing['status'], 404);
  });

  test('PUT /v1/teams/{id} memperbarui nama; DELETE menghapus (404 berikut)',
      () async {
    final upd = await send('PUT', '/v1/teams/paket-ui', body: {
      'name': 'Nama Baru',
    });
    expect(upd['status'], 200);
    expect(upd['body']['name'], 'Nama Baru');
    final del = await send('DELETE', '/v1/teams/paket-ui');
    expect(del['status'], 200);
    expect(del['body']['deleted'], isTrue);
    final gone = await send('GET', '/v1/teams/paket-ui');
    expect(gone['status'], 404);
  });

  test('POST /v1/teams/run menjalankan orkestra (sinkron) dan mencatat run',
      () async {
    final r = await send('POST', '/v1/teams/run', body: {
      'goal': 'riset pasar',
      'team_id': 'paket-ui',
    });
    expect(r['status'], 200);
    expect(r['body']['success'], isTrue);
    expect(r['body']['run_id'], 't-x');
    final listed = await send('GET', '/v1/teams/runs');
    expect((listed['body']['runs'] as List), hasLength(1));
  });

  test('POST /v1/teams/run tanpa goal 400', () async {
    final r = await send('POST', '/v1/teams/run', body: {'team_id': 'x'});
    expect(r['status'], 400);
    expect(r['body']['code'], 'invalid_request');
  });

  test('POST /v1/teams/run max_concurrency di luar 1..8 → 400', () async {
    final r = await send('POST', '/v1/teams/run', body: {
      'goal': 'g',
      'max_concurrency': 9,
    });
    expect(r['status'], 400);
  });

  test('endpoint team tanpa konfigurasi host → 501', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/teams');
      final request = await client.openUrl('GET', uri);
      request.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(response.statusCode, 501);
      expect(body['code'], 'not_implemented');
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });
}
