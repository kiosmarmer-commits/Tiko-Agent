import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audit query browser (GUI-P1-11) di atas fake agentd: GET /v1/audit
/// dengan filter query string.
void main() {
  group('GUI-P1-11: repository audit', () {
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

    test('audit() mengembalikan hasil typed lengkap', () async {
      final r = await repo.audit(tool: 'shell', risk: 'high');
      expect(r.total, 2);
      expect(r.entries.length, 2);
      expect(r.entries[0].tool, 'shell.exec');
      expect(r.entries[0].risk, 'high');
      expect(r.entries[0].session, 'web:default');
      expect(r.entries[0].durationMs, 42);
      expect(r.entries[1].verdict, 'deny');
      expect(r.entries[1].taint, isTrue);
      expect(r.entries[1].args, {'cmd': 'rm'});
    });

    test('parameter filter dan paginasi dikirim sebagai query string',
        () async {
      await repo.audit(
        tool: 'shell',
        session: 'web:default',
        verdict: 'deny',
        taint: true,
        limit: 10,
        offset: 5,
      );
      expect(fake.lastPath, '/v1/audit');
      expect(
          fake.lastQueries,
          containsAll([
            'tool=shell',
            'session=web:default',
            'verdict=deny',
            'taint=true',
            'limit=10',
            'offset=5',
          ]));
      expect(fake.lastQueries.any((q) => q.startsWith('risk=')), isFalse);
    });

    test('filter kosong tetap mengirim limit/offset default', () async {
      await repo.audit();
      expect(fake.lastPath, '/v1/audit');
      expect(fake.lastQueries.contains('limit=50'), isTrue);
      expect(fake.lastQueries.contains('offset=0'), isTrue);
    });

    test('bearer tetap di header', () async {
      await repo.audit();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.audit();
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
  String lastPath = '';
  Set<String> lastQueries = {};
  int nextErrorCode = 0;
  String? nextErrorCodeName;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        lastPath = req.uri.path;
        lastQueries = req.uri.queryParametersAll.entries
            .expand((e) => e.value.map((v) => '${e.key}=$v'))
            .toSet();
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (lastPath == '/v1/audit') lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'audit not configured',
            'retryable': false,
          }));
        } else if (lastPath == '/v1/audit' && req.method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'total': 2,
            'entries': [
              {
                'ts': '2026-11-18T13:00:00.000Z',
                'session': 'web:default',
                'tool': 'shell.exec',
                'args': {'cmd': 'ls'},
                'risk': 'high',
                'verdict': 'approve',
                'result': 'ok',
                'duration_ms': 42,
                'error': null,
                'taint': false,
              },
              {
                'ts': '2026-11-18T12:59:00.000Z',
                'session': 's-2',
                'tool': 'file.write',
                'args': {'cmd': 'rm'},
                'risk': 'high',
                'verdict': 'deny',
                'result': null,
                'duration_ms': null,
                'error': 'ditolak',
                'taint': true,
              },
            ],
          }));
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
