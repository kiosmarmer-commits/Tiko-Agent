import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bot Manager (GUI-P1-04) di atas fake agentd: CRUD profil bot + binding
/// sesi, dengan error model typed (400/404/409/501).
void main() {
  group('GUI-P1-04: repository bots', () {
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

    test('bots() mengembalikan List<BotProfileItem>', () async {
      final bots = await repo.bots();
      expect(bots.length, 2);
      expect(bots[0].id, 'helper');
      expect(bots[0].model, 'm1');
      expect(bots[1].toolAllowlist, ['read_file']);
      expect(bots[0].persona, 'rapih');
    });

    test('createBot() POST dan mengembalikan profil dengan status 201',
        () async {
      final bot = await repo.createBot({
        'id': 'notaris',
        'name': 'Notaris',
        'persona': 'formal',
        'model': 'gpt-x',
        'greeting': 'halo',
        'tool_allowlist': ['read_file'],
      });
      expect(bot.id, 'notaris');
      expect(fake.lastCreateBody['id'], 'notaris');
      expect(fake.lastCreateStatus, 201);
      expect(fake.lastCreatePath, '/v1/bots');
    });

    test('createBot duplikat 409 conflict menjadi ApiError(context conflict)',
        () async {
      try {
        await repo.createBot({'id': 'helper', 'name': 'Dup'});
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.conflict);
      }
    });

    test('createBot id tidak valid 400 invalid_request', () async {
      try {
        await repo.createBot({'id': 'Bad ID!', 'name': 'X'});
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.invalidRequest);
        expect(e.message, contains('id'));
      }
    });

    test('updateBot() PATCH subset termasuk clear model (null)', () async {
      final bot = await repo.updateBot('helper', {
        'name': 'Helper Baru',
        'model': null,
      });
      expect(bot.name, 'Helper Baru');
      expect(bot.model, isNull);
      expect(fake.lastPatchPath, '/v1/bots/helper');
    });

    test('updateBot() 404 not_found menjadi ApiError(notFound)', () async {
      try {
        await repo.updateBot('unknown-bot', {'name': 'X'});
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notFound);
      }
    });

    test('deleteBot() DELETE sukses true, gagal 404 false', () async {
      expect(await repo.deleteBot('scribe'), isTrue);
      expect(await repo.deleteBot('unknown-bot'), isFalse);
      expect(fake.lastDeletePath, '/v1/bots/unknown-bot');
    });

    test('botBindings() mengembalikan Map<String, String>', () async {
      final bindings = await repo.botBindings();
      expect(bindings, {'ws:lab': 'helper'});
    });

    test('bindBot()/unbindBot() POST dan mengembalikan bool', () async {
      expect(await repo.bindBot('helper', 'ws:baru'), isTrue);
      expect(fake.lastBindPath, '/v1/bots/helper/bind');
      expect(fake.lastBindBody['session_id'], 'ws:baru');

      expect(await repo.unbindBot('helper', 'ws:baru'), isTrue);
      expect(fake.lastBindPath, '/v1/bots/helper/unbind');

      expect(await repo.bindBot('unknown-bot', 'ws:baru'), isFalse);
    });

    test('bearer tetap di header, bukan query', () async {
      await repo.bots();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback bot 501 not_implemented menjadi ApiError',
        () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.bots();
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notImplemented);
      }
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  Map<String, dynamic> lastCreateBody = {};
  String lastCreatePath = '';
  int lastCreateStatus = 0;
  String lastPatchPath = '';
  String lastDeletePath = '';
  String lastBindPath = '';
  Map<String, dynamic> lastBindBody = {};
  String lastAuthHeader = '';
  int nextErrorCode = 0;
  String? nextErrorCodeName;

  static const _notFound = <String, dynamic>{
    'ok': false,
    'code': 'not_found',
    'error': 'bot not found',
    'retryable': false,
  };

  static const _conflict = <String, dynamic>{
    'ok': false,
    'code': 'conflict',
    'error': 'bot "helper" sudah ada',
    'retryable': false,
  };

  static const _invalid = <String, dynamic>{
    'ok': false,
    'code': 'invalid_request',
    'error': 'id bot wajib [a-z0-9][a-z0-9_-]{0,63}',
    'retryable': false,
  };

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/bots')) lastAuthHeader = auth;

        Future<Map<String, dynamic>> body() async =>
            Map<String, dynamic>.from(
                jsonDecode(await utf8.decoder.bind(req).join()) as Map);

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'daemon tanpa bot manager',
            'retryable': false,
          }));
        } else if (path == '/v1/bots' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'bots': [
              {
                'id': 'helper',
                'name': 'Helper',
                'persona': 'rapih',
                'model': 'm1',
                'greeting': 'hai',
                'tool_allowlist': <String>[],
                'created_at': '2026-11-18T09:00:00.000Z',
                'updated_at': '2026-11-18T09:00:00.000Z',
              },
              {
                'id': 'scribe',
                'name': 'Scribe',
                'persona': '',
                'model': null,
                'greeting': '',
                'tool_allowlist': ['read_file'],
                'created_at': '2026-11-18T09:00:00.000Z',
                'updated_at': '2026-11-18T09:00:00.000Z',
              },
            ],
          }));
        } else if (path == '/v1/bots' && method == 'POST') {
          lastCreatePath = path;
          lastCreateStatus = 200;
          final payload = await body();
          if (payload['id'] == 'helper') {
            lastCreateStatus = 409;
            req.response.statusCode = 409;
            req.response.write(jsonEncode(_conflict));
          } else if ((payload['id'] as String? ?? '').contains(' ')) {
            lastCreateStatus = 400;
            req.response.statusCode = 400;
            req.response.write(jsonEncode(_invalid));
          } else {
            lastCreateStatus = 201;
            lastCreateBody = payload;
            req.response.statusCode = 201;
            req.response.write(jsonEncode(<String, dynamic>{
              ...payload,
              'created_at': '2026-11-18T09:00:00.000Z',
              'updated_at': '2026-11-18T09:00:00.000Z',
            }));
          }
        } else if (path == '/v1/bots/bindings' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'bindings': {'ws:lab': 'helper'},
          }));
        } else if (path.startsWith('/v1/bots/') && method == 'PATCH') {
          lastPatchPath = path;
          final payload = await body();
          if (path == '/v1/bots/unknown-bot') {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(_notFound));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{
              'id': path.substring('/v1/bots/'.length),
              'name': payload['name'] ?? 'Helper',
              'persona': 'rapih',
              'model': payload.containsKey('model')
                  ? payload['model']
                  : 'm1',
              'greeting': 'hai',
              'tool_allowlist': <String>[],
              'created_at': '2026-11-18T09:00:00.000Z',
              'updated_at': '2026-11-18T09:00:00.000Z',
            }));
          }
        } else if (path.startsWith('/v1/bots/') && method == 'DELETE') {
          lastDeletePath = path;
          if (path == '/v1/bots/unknown-bot') {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(_notFound));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{'deleted': true}));
          }
        } else if ((path.endsWith('/bind') || path.endsWith('/unbind')) &&
            method == 'POST') {
          lastBindPath = path;
          lastBindBody = await body();
          if (path.startsWith('/v1/bots/unknown-bot')) {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(_notFound));
          } else {
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'bound': path.endsWith('/bind'),
            }));
          }
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(_notFound));
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
