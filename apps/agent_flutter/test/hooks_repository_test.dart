import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// SETTINGS-HOOKS (Codex item 1): repository typed di atas fake agentd —
/// GET/POST/PATCH/DELETE `/v1/hooks*` dan test fire `/v1/hooks/test`.
void main() {
  group('SETTINGS-HOOKS: repository hooks', () {
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

    test('hooks() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.hooks();
      expect(snap.rules.length, 2);
      expect(snap.rules[0].event, 'model.switched');
      expect(snap.rules[0].webhookUrl, 'https://contoh.io/hook');
      expect(snap.rules[0].timeoutSec, 30);
      expect(snap.rules[1].script, 'scripts/notify.sh');
      expect(snap.rules[1].env, {'API_KEY': 'xyz'});
      expect(snap.stats['hooks[0]:webhook']?.fires, 3);
      expect(snap.stats['hooks[0]:webhook']?.failures, 1);
      expect(snap.stats['hooks[0]:webhook']?.lastError, 'timeout');
    });

    test('addHook POST body event/webhook/timeout_sec', () async {
      await repo.addHook({
        'event': 'session.*',
        'webhook': 'https://x.io/hook',
        'timeout_sec': 15,
      });
      expect(fake.lastAddPath, '/v1/hooks');
      expect(fake.lastAddBody, {
        'event': 'session.*',
        'webhook': 'https://x.io/hook',
        'timeout_sec': 15,
      });
    });

    test('updateHook PATCH path berindeks + deleteHook DELETE', () async {
      await repo.updateHook(1, {
        'event': 'session.*',
        'script': 'scripts/a.sh',
        'timeout_sec': 10,
      });
      expect(fake.lastUpdatePath, '/v1/hooks/1');
      await repo.deleteHook(2);
      expect(fake.lastDeletePath, '/v1/hooks/2');
    });

    test('testHook POST /v1/hooks/test dengan index int', () async {
      final result = await repo.testHook(0);
      expect(fake.lastTestPath, '/v1/hooks/test');
      expect(fake.lastTestBody, {'index': 0});
      expect(result['results'], isA<List<dynamic>>());
    });

    test('payload invalid 400 → ApiError invalidRequest', () async {
      try {
        await repo.addHook({'event': '', 'timeout_sec': 999});
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.statusCode, 400);
      }
    });

    test('hooks() bearer tetap di header', () async {
      await repo.hooks();
      expect(fake.lastAuthHeader, 'Bearer t');
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';
  String lastAddPath = '';
  Map<String, dynamic> lastAddBody = {};
  String lastUpdatePath = '';
  String lastDeletePath = '';
  String lastTestPath = '';
  Map<String, dynamic> lastTestBody = {};

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/hooks')) lastAuthHeader = auth;

        if (path == '/v1/hooks' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'rules': [
              {
                'event': 'model.switched',
                'webhook': 'https://contoh.io/hook',
                'timeout_sec': 30,
              },
              {
                'event': 'session.*',
                'script': 'scripts/notify.sh',
                'timeout_sec': 12,
                'env': {'API_KEY': 'xyz'},
              },
            ],
            'stats': {
              'hooks[0]:webhook': {
                'fires': 3,
                'failures': 1,
                'last_error': 'timeout',
                'last_at': '2026-02-11T00:00:00.000Z',
              },
            },
          }));
        } else if (path == '/v1/hooks' && method == 'POST') {
          lastAddPath = path;
          lastAddBody = Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(req).join()) as Map);
          final valid = '${lastAddBody['event']}'.isNotEmpty &&
              lastAddBody['timeout_sec'] is int &&
              ((lastAddBody['timeout_sec'] as int) >= 1 &&
                  (lastAddBody['timeout_sec'] as int) <= 120);
          if (!valid) {
            req.response.statusCode = 400;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': false,
              'code': 'invalid_request',
              'error': 'event wajib diisi dan timeout 1..120',
              'retryable': false,
            }));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'rules': <Map<String, dynamic>>[],
              'stats': <String, dynamic>{},
            }));
          }
        } else if (path == '/v1/hooks/test' && method == 'POST') {
          lastTestPath = path;
          lastTestBody = Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(req).join()) as Map);
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'index': lastTestBody['index'],
            'results': [
              {'target': 'webhook', 'ok': true},
            ],
            'stats': <String, dynamic>{},
          }));
        } else if (RegExp(r'^/v1/hooks/\d+$').hasMatch(path) &&
            method == 'PATCH') {
          lastUpdatePath = path;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'rules': <Map<String, dynamic>>[],
            'stats': <String, dynamic>{},
          }));
        } else if (RegExp(r'^/v1/hooks/\d+$').hasMatch(path) &&
            method == 'DELETE') {
          lastDeletePath = path;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'rules': <Map<String, dynamic>>[],
            'stats': <String, dynamic>{},
          }));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'endpoint tidak dikenal: $method $path',
            'retryable': false,
          }));
        }
        await req.response.close();
      }
    }());
    return 'http://localhost:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
