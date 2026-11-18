import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run-inspector (GUI-P2-04) di atas fake agentd: snapshot {active, recent,
/// truncated} read-only dengan steps typed.
void main() {
  group('GUI-P2-04: repository run-inspector', () {
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

    test('runInspector() mengembalikan snapshot typed', () async {
      final r = await repo.runInspector();
      expect(r.active, hasLength(1));
      final run = r.active.first;
      expect(run.id, 'run-1');
      expect(run.session, 'web:1');
      expect(run.running, isTrue);
      expect(run.subagent, isFalse);
      expect(run.steps.first.tool, 'datetime');
      expect(run.steps.first.isError, isFalse);
      expect(fake.lastPath, '/v1/runs');
    });

    test('run riwayat + subagent + error typed', () async {
      fake.nextScenario = _Scenario.recentSubagent;
      final r = await repo.runInspector();
      final run = r.recent.first;
      expect(run.running, isFalse);
      expect(run.success, isFalse);
      expect(run.error, 'boom');
      expect(run.subagent, isTrue);
      expect(run.parent, 'web:1');
      expect(run.tokensUsed, 80);
    });

    test('bearer tetap di header', () async {
      await repo.runInspector();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.runInspector();
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notImplemented);
      }
    });
  });
}

enum _Scenario { active, recentSubagent }

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';
  String lastPath = '';
  int nextErrorCode = 0;
  String? nextErrorCodeName;
  _Scenario nextScenario = _Scenario.active;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        lastPath = req.uri.path;
        lastAuthHeader = req.headers.value('authorization') ?? '';
        req.response.headers.contentType = ContentType.json;
        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'runs not configured',
            'retryable': false,
          }));
          await req.response.close();
          continue;
        }
        req.response.write(jsonEncode(
            nextScenario == _Scenario.active ? _activePayload : _recentPayload));
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  static final _activePayload = <String, dynamic>{
    'active': [
      {
        'id': 'run-1',
        'session': 'web:1',
        'channel': 'web',
        'subagent': false,
        'parent': null,
        'input': 'halo',
        'state': 'running',
        'started_at': '2026-11-18T13:00:00.000Z',
        'ended_at': null,
        'duration_ms': null,
        'success': null,
        'tokens_used': 0,
        'tool_calls': 0,
        'answer': null,
        'error': null,
        'steps': [
          {
            'tool': 'datetime',
            'verdict': 'allowed',
            'is_error': false,
            'duration_ms': 12,
            'at': '2026-11-18T13:00:01.000Z',
          },
        ],
      },
    ],
    'recent': <Map<String, dynamic>>[],
    'truncated': false,
  };

  static final _recentPayload = <String, dynamic>{
    'active': <Map<String, dynamic>>[],
    'recent': [
      {
        'id': 'run-2',
        'session': 'web:1/sub/1/1',
        'channel': 'web',
        'subagent': true,
        'parent': 'web:1',
        'input': 'sub',
        'state': 'error',
        'started_at': '2026-11-18T13:00:00.000Z',
        'ended_at': '2026-11-18T13:00:02.000Z',
        'duration_ms': 2000,
        'success': false,
        'tokens_used': 80,
        'tool_calls': 1,
        'answer': null,
        'error': 'boom',
        'steps': <Map<String, dynamic>>[],
      },
    ],
    'truncated': false,
  };

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
