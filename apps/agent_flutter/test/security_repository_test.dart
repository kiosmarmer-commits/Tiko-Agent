import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Security Center (GUI-P1-10) di atas fake agentd: snapshot read-only
/// konsolidasi dari GET /v1/security.
void main() {
  group('GUI-P1-10: repository security', () {
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

    test('security() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.security();
      expect(snap.safeMode, isFalse);
      expect(snap.panic, isTrue);
      expect(snap.stopRequested, isFalse);
      expect(snap.sandbox, 'landlock');
      expect(snap.sealedStorage, isTrue);
      expect(snap.activeSessions, 2);

      expect(snap.plugins.length, 2);
      expect(snap.plugins[0].id, 'weather');
      expect(snap.plugins[0].registered, isTrue);
      expect(snap.plugins[0].grantedCount, 3);
      expect(snap.plugins[1].pending, isTrue);
      expect(snap.plugins[1].grantedCount, 0);

      expect(snap.tokenAnomalyEnabled, isTrue);
      expect(snap.quarantinesToday, 1);
      expect(snap.maxQuarantinesPerDay, 5);
      expect(snap.tokenSkillStats.length, 1);
      expect(snap.tokenSkillStats[0].slug, 'berita');
      expect(snap.tokenSkillStats[0].samples, 42);

      expect(snap.rateWindowSec, 60);
      expect(snap.rateMaxEvents, 40);
      expect(snap.guardBlockedTurns, 2);
      expect(snap.guardSanitizedTurns, 7);
      expect(snap.auditTotal, 320);
      expect(snap.auditRecent.length, 2);
      expect(snap.auditRecent[0]['tool'], 'shell.exec');
    });

    test('snapshot minim tanpa field optional tetap aman', () async {
      fake.minimal = true;
      final snap = await repo.security();
      expect(snap.safeMode, isFalse);
      expect(snap.sandbox, 'none');
      expect(snap.plugins, isEmpty);
      expect(snap.tokenSkillStats, isEmpty);
      expect(snap.auditRecent, isEmpty);
      expect(snap.activeSessions, 0);
    });

    test('bearer tetap di header', () async {
      await repo.security();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.security();
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
  bool minimal = false;
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
        if (path == '/v1/security') lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'security not configured',
            'retryable': false,
          }));
        } else if (path == '/v1/security' && method == 'GET' && !minimal) {
          req.response.write(jsonEncode(<String, dynamic>{
            'safety': {
              'safe_mode': false,
              'panic': true,
              'stop_requested': false,
            },
            'sandbox': 'landlock',
            'credentials': {'sealed_storage': true},
            'plugins': [
              {
                'id': 'weather',
                'registered': true,
                'pending': false,
                'granted_count': 3,
                'requested_count': 3,
              },
              {
                'id': 'database',
                'registered': true,
                'pending': true,
                'granted_count': 0,
                'requested_count': 2,
              },
            ],
            'token_anomaly': {
              'enabled': true,
              'quarantines_today': 1,
              'max_quarantines_per_day': 5,
              'skills': [
                {'slug': 'berita', 'samples': 42},
              ],
            },
            'rate_anomaly': {'window_sec': 60, 'max_events': 40},
            'guard': {'blocked_turns': 2, 'sanitized_turns': 7},
            'audit': {
              'total_in_memory': 320,
              'recent': [
                {
                  'ts': '2026-11-18T13:00:00.000Z',
                  'tool': 'shell.exec',
                  'risk': 'high',
                  'verdict': 'allowed',
                  'session': 's-1',
                },
                {
                  'ts': '2026-11-18T12:59:00.000Z',
                  'tool': 'web.fetch',
                  'risk': 'low',
                  'verdict': 'sanitized',
                  'session': 's-2',
                },
              ],
            },
            'active_sessions': 2,
          }));
        } else if (path == '/v1/security' && method == 'GET') {
          req.response
              .write(jsonEncode(<String, dynamic>{'sandbox': 'none'}));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'not found',
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
