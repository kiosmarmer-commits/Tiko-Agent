import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Automation / cron CRUD (GUI-P1-09) di atas fake agentd: list, create,
/// update (toggle), delete, run-now.
void main() {
  group('GUI-P1-09: repository jobs', () {
    late _ApiServer fake;
    late AgentApiClient client;
    late HttpAgentRepository repo;

    setUp(() async {
      fake = _ApiServer();
      client = AgentApiClient(baseUrl: await fake.start(), token: 't');
      repo = HttpAgentRepository(client);
    });

    tearDown(() async {
      client.close();
      await fake.close();
    });

    test('jobs() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.jobs();
      expect(snap.jobs.length, 2);
      expect(snap.jobs[0].id, 'job-1');
      expect(snap.jobs[0].cron, '*/5 * * * *');
      expect(snap.jobs[0].enabled, isTrue);
      expect(snap.jobs[0].deliveryState, 'none');
      expect(snap.jobs[1].missedPolicy, 'skip');
      expect(snap.jobs[1].timezone, 'Asia/Jakarta');
      expect(snap.jobs[1].enabled, isFalse);
    });

    test('createJob memetakan body ke JobInfo (snake_case -> camelCase)',
        () async {
      final job = await repo.createJob({
        'cron': '0 9 * * *',
        'prompt': 'laporan harian',
        'channel': 'http',
        'user_key': 'admin',
        'missed_policy': 'run_once',
      });
      expect(job.id, 'job-baru');
      expect(job.cron, '0 9 * * *');
      expect(job.prompt, 'laporan harian');
      expect(job.userKey, 'admin');
      expect(job.missedPolicy, 'runOnce');
      expect(job.deliveryState, 'none');
    });

    test('updateJob toggle enabled + PATCH parsial', () async {
      final job = await repo.updateJob('job-1', {'enabled': false});
      expect(job.enabled, isFalse);
      expect(fake.lastPatchBody!['enabled'], false);
    });

    test('deleteJob mengembalikan false untuk 404', () async {
      expect(await repo.deleteJob('job-1'), isTrue);
      expect(await repo.deleteJob('job-asing'), isFalse);
    });

    test('runJobNow mengembalikan job; null untuk 404 (asing/busy)',
        () async {
      final job = await repo.runJobNow('job-1');
      expect(job, isNotNull);
      expect(job!.nextRun, isNotEmpty);
      expect(await repo.runJobNow('job-asing'), isNull);
    });

    test('bearer tetap di header', () async {
      await repo.jobs();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.jobs();
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notImplemented);
      }
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';
  Map<String, dynamic>? lastPatchBody;
  bool deleted = false;
  int nextErrorCode = 0;
  String? nextErrorCodeName;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/jobs')) lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'scheduler not configured',
            'retryable': false,
          }));
        } else if (path == '/v1/jobs' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'jobs': [
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
                'delivery_state': 'none',
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
                'last_run': '2026-11-18T02:00:00.000Z',
                'delivery_state': 'delivered',
              },
            ],
          }));
        } else if (path == '/v1/jobs' && method == 'POST') {
          final body =
              jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          req.response.statusCode = 201;
          req.response.write(jsonEncode(<String, dynamic>{
            ...Map<String, dynamic>.from(body),
            'id': 'job-baru',
            'enabled': true,
            'missed_policy': 'runOnce',
            'timezone': 'UTC',
            'next_run': '2026-11-18T13:05:00.000Z',
            'delivery_state': 'none',
          }));
        } else if (path.startsWith('/v1/jobs/') && method == 'PATCH') {
          final body = Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(req).join()) as Map);
          lastPatchBody = body;
          req.response.write(jsonEncode(<String, dynamic>{
            'id': 'job-1',
            'cron': '*/5 * * * *',
            'prompt': 'ringkas berita',
            'channel': 'http',
            'user_key': 'admin',
            'enabled': false,
            'missed_policy': 'runOnce',
            'timezone': 'UTC',
            'next_run': '2026-11-18T13:05:00.000Z',
            'delivery_state': 'none',
          }));
        } else if (path == '/v1/jobs/job-1/run' && method == 'POST') {
          req.response.write(jsonEncode(<String, dynamic>{
            'id': 'job-1',
            'cron': '*/5 * * * *',
            'prompt': 'ringkas berita',
            'channel': 'http',
            'user_key': 'admin',
            'enabled': true,
            'missed_policy': 'runOnce',
            'timezone': 'UTC',
            'next_run': DateTime.now().toUtc().toIso8601String(),
            'delivery_state': 'none',
          }));
        } else if (path == '/v1/jobs/job-1' && method == 'DELETE') {
          deleted = true;
          req.response
              .write(jsonEncode(<String, dynamic>{'deleted': true}));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'job not found',
            'retryable': false,
          }));
        }
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
