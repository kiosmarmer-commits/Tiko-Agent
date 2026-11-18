import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-09: automation / cron CRUD — endpoint /v1/jobs di atas callback
/// wiring job store scheduler (list, create, update, delete, run-now).
void main() {
  late HttpApiServer server;
  final jobs = <Map<String, dynamic>>[
    {
      'id': 'job-1',
      'cron': '*/5 * * * *',
      'prompt': 'ringkas berita',
      'channel': 'http',
      'user_key': 'admin',
      'enabled': true,
      'missed_policy': 'runOnce',
      'timezone': 'UTC',
      'next_run': '2026-11-18T13:00:00.000Z',
    },
    {
      'id': 'job-2',
      'cron': '0 9 * * *',
      'prompt': 'backup harian',
      'channel': 'telegram',
      'user_key': 'scheduler',
      'enabled': false,
      'missed_policy': 'skip',
      'timezone': 'Asia/Jakarta',
      'next_run': '2026-11-19T02:00:00.000Z',
    },
  ];

  setUp(() async {
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      jobsProvider: () async => jobs,
      createJob: (body) async {
        final job = <String, dynamic>{
          'id': 'job-baru',
          'cron': body['cron'] as String,
          'prompt': body['prompt'] as String,
          'channel': body['channel'] ?? 'http',
          'user_key': body['user_key'] ?? 'admin',
          'enabled': body['enabled'] ?? true,
          'missed_policy': body['missed_policy'] ?? 'runOnce',
          'timezone': body['timezone'] ?? 'UTC',
          'next_run': '2026-11-18T13:05:00.000Z',
        };
        jobs.add(job);
        return job;
      },
      updateJob: (id, body) async {
        final hit = jobs.where((j) => j['id'] == id).toList();
        if (hit.isEmpty) return null;
        hit.first.addAll(body);
        return hit.first;
      },
      deleteJob: (id) async {
        final hit = jobs.where((j) => j['id'] == id).toList();
        if (hit.isEmpty) return false;
        jobs.remove(hit.first);
        return true;
      },
      runJobNow: (id) async {
        final hit = jobs.where((j) => j['id'] == id).toList();
        if (hit.isEmpty) return null;
        hit.first['next_run'] = DateTime.now().toUtc().toIso8601String();
        return hit.first;
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

  test('GET /v1/jobs mengembalikan daftar job', () async {
    final r = await send('GET', '/v1/jobs');
    expect(r['status'], 200);
    final list = r['body']['jobs'] as List;
    expect(list.length, 2);
    expect(list[0]['id'], 'job-1');
    expect(list[0]['cron'], '*/5 * * * *');
    expect(list[1]['timezone'], 'Asia/Jakarta');
  });

  test('GET /v1/jobs tanpa auth 401', () async {
    final r = await send('GET', '/v1/jobs', auth: false);
    expect(r['status'], 401);
  });

  test('POST /v1/jobs membuat job (201) dengan default', () async {
    final r = await send(
      'POST',
      '/v1/jobs',
      body: {
        'cron': '0 9 * * *',
        'prompt': 'harian',
        'channel': 'http',
        'user_key': 'admin',
      },
    );
    expect(r['status'], 201);
    expect(r['body']['id'], 'job-baru');
    expect(r['body']['missed_policy'], 'runOnce');
    expect(r['body']['timezone'], 'UTC');
    expect(r['body']['enabled'], isTrue);
  });

  test('POST /v1/jobs tanpa cron atau prompt 400', () async {
    final r1 = await send('POST', '/v1/jobs', body: {'prompt': 'x'});
    expect(r1['status'], 400);
    expect(r1['body']['code'], 'invalid_request');
    final r2 = await send('POST', '/v1/jobs', body: {'cron': '* * * * *'});
    expect(r2['status'], 400);
  });

  test('POST /v1/jobs field tak dikenal + missed_policy invalid 400', () async {
    final r1 = await send(
      'POST',
      '/v1/jobs',
      body: {'cron': '* * * * *', 'prompt': 'p', 'hacked': true},
    );
    expect(r1['status'], 400);
    expect(r1['body']['error'], contains('field tidak dikenal'));
    final r2 = await send(
      'POST',
      '/v1/jobs',
      body: {'cron': '* * * * *', 'prompt': 'p', 'missed_policy': 'selalu'},
    );
    expect(r2['status'], 400);
    final r3 = await send(
      'POST',
      '/v1/jobs',
      body: {'cron': '* * * * *', 'prompt': 'p', 'enabled': 'yes'},
    );
    expect(r3['status'], 400);
  });

  test('PATCH /v1/jobs/:id memutasi job, 404 untuk id asing', () async {
    final r1 = await send(
      'PATCH',
      '/v1/jobs/job-2',
      body: {'enabled': true, 'missed_policy': 'catch_up'},
    );
    expect(r1['status'], 200);
    expect(r1['body']['enabled'], isTrue);
    expect(r1['body']['missed_policy'], 'catch_up');
    final r2 = await send(
      'PATCH',
      '/v1/jobs/tidak-ada',
      body: {'enabled': false},
    );
    expect(r2['status'], 404);
    expect(r2['body']['code'], 'not_found');
  });

  test('DELETE /v1/jobs/:id menghapus job, 404 untuk id asing', () async {
    final r1 = await send('DELETE', '/v1/jobs/job-2');
    expect(r1['status'], 200);
    expect(r1['body']['deleted'], isTrue);
    final r2 = await send('DELETE', '/v1/jobs/job-2');
    expect(r2['status'], 404);
  });

  test('POST /v1/jobs/:id/run memajukan next_run, 404 untuk id asing',
      () async {
    final r1 = await send('POST', '/v1/jobs/job-1/run');
    expect(r1['status'], 200);
    expect(r1['body']['next_run'], isNotEmpty);
    final r2 = await send('POST', '/v1/jobs/tidak-ada/run');
    expect(r2['status'], 404);
  });

  test('daemon tanpa callback jobs 501 not_implemented', () async {
    final bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${bare.boundPort}/v1/jobs');
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
