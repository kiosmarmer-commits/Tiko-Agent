import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Provider & Model Manager (GUI-P1-05) di atas fake agentd: snapshot
/// provider + health breaker, mapping tier, override sesi (`/model` parity).
void main() {
  group('GUI-P1-05: repository providers', () {
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

    test('providers() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.providers();
      expect(snap.defaultId, 'mock-1');
      expect(snap.providers.length, 2);
      expect(snap.providers[0].id, 'mock-1');
      expect(snap.providers[0].toolCalling, isTrue);
      expect(snap.providers[0].vision, isFalse);
      expect(snap.providers[0].maxContext, 8192);
      expect(snap.providers[0].health?.phase, 'closed');
      expect(snap.providers[0].health?.successes, 9);
      expect(snap.providers[1].health, isNull);
      expect(snap.tiers, {'1': 'mock-1', '3': 'mock-2'});
      expect(snap.sessionOverrides, {'ws:lab': 'mock-2'});
      expect(snap.sessionModelChoices, {'ws:lab': 'mock-x'});
    });

    test('setSessionProvider() POST body session_id + provider', () async {
      final ok = await repo.setSessionProvider('ws:baru', 'mock-1');
      expect(ok, isTrue);
      expect(fake.lastSetPath, '/v1/providers/session');
      expect(fake.lastSetBody,
          {'session_id': 'ws:baru', 'provider': 'mock-1'});
    });

    test('setSessionProvider() dengan model opsional (discovery)', () async {
      final ok = await repo.setSessionProvider(
        'ws:baru',
        'mock-1',
        model: 'mock-1-turbo',
      );
      expect(ok, isTrue);
      expect(fake.lastSetBody, {
        'session_id': 'ws:baru',
        'provider': 'mock-1',
        'model': 'mock-1-turbo',
      });
    });

    test('providerModels() parsing daftar model live discovery', () async {
      final models = await repo.providerModels('mock-1');
      expect(fake.lastModelsPath, '/v1/providers/mock-1/models');
      expect(models, ['mock-1-base', 'mock-1-turbo']);
    });

    test("setSessionProvider('default') melepas override", () async {
      final ok = await repo.setSessionProvider('ws:lab', 'default');
      expect(ok, isTrue);
      expect(fake.lastSetBody['provider'], 'default');
      expect(fake.overrides.containsKey('ws:lab'), isFalse);
    });

    test('provider tidak dikenal 404 → false', () async {
      expect(await repo.setSessionProvider('ws:lab', 'grid-9'), isFalse);
    });

    test('bearer tetap di header', () async {
      await repo.providers();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.providers();
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notImplemented);
      }
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  Map<String, dynamic> lastSetBody = {};
  String lastSetPath = '';
  String lastModelsPath = '';
  String lastAuthHeader = '';
  Map<String, String> overrides = {'ws:lab': 'mock-2'};
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
        if (path.startsWith('/v1/providers')) lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'daemon tanpa provider manager',
            'retryable': false,
          }));
        } else if (path == '/v1/providers' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'default': 'mock-1',
            'providers': [
              {
                'id': 'mock-1',
                'capabilities': {
                  'tool_calling': true,
                  'vision': false,
                  'streaming': true,
                  'max_context': 8192,
                },
                'health': {
                  'failures': 0,
                  'successes': 9,
                  'open': false,
                  'phase': 'closed',
                  'last_error': null,
                  'last_latency_ms': 12.5,
                },
              },
              {'id': 'mock-2', 'capabilities': null, 'health': null},
            ],
            'tiers': {'1': 'mock-1', '3': 'mock-2'},
            'session_overrides': overrides,
            'session_model_choices': {'ws:lab': 'mock-x'},
          }));
        } else if (path.startsWith('/v1/providers/') &&
            path.endsWith('/models') &&
            method == 'GET') {
          lastModelsPath = path;
          if (path == '/v1/providers/mock-1/models') {
            req.response.write(jsonEncode(<String, dynamic>{
              'provider': 'mock-1',
              'models': <String>['mock-1-base', 'mock-1-turbo'],
              'count': 2,
              'discovered': true,
            }));
          } else {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': false,
              'code': 'not_found',
              'error': 'provider tidak dikenal',
              'retryable': false,
            }));
          }
        } else if (path == '/v1/providers/session' && method == 'POST') {
          lastSetPath = path;
          lastSetBody = Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(req).join()) as Map);
          final arg = '${lastSetBody['provider']}';
          if (arg == 'grid-9') {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': false,
              'code': 'not_found',
              'error': 'provider not found',
              'retryable': false,
            }));
          } else if (arg.toLowerCase() == 'default') {
            overrides.clear();
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'session_id': lastSetBody['session_id'],
              'provider': arg,
            }));
          } else {
            overrides[lastSetBody['session_id'] as String] = arg;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'session_id': lastSetBody['session_id'],
              'provider': arg,
            }));
          }
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
