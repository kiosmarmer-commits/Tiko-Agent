import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Channels setup (GUI-P1-07) di atas fake agentd: status channel gateway +
/// nama env (read-only).
void main() {
  group('GUI-P1-07: repository channels', () {
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

    test('channels() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.channels();
      expect(snap.channels.length, 3);
      expect(snap.channels[0].channel, 'telegram');
      expect(snap.channels[0].active, isTrue);
      expect(snap.channels[0].env, ['TG_TOKEN', 'TG_ALLOW']);
      expect(snap.channels[1].active, isFalse);
      expect(snap.channels[2].env, isEmpty);
    });

    test('bearer tetap di header', () async {
      await repo.channels();
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('daemon tanpa callback 501 not_implemented', () async {
      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.channels();
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
        if (path.startsWith('/v1/channels')) lastAuthHeader = auth;

        if (nextErrorCode != 0) {
          req.response.statusCode = nextErrorCode;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'channels not configured',
            'retryable': false,
          }));
        } else if (path == '/v1/channels' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'channels': [
              {
                'channel': 'telegram',
                'active': true,
                'env': ['TG_TOKEN', 'TG_ALLOW'],
              },
              {
                'channel': 'discord',
                'active': false,
                'env': ['DISCORD_BOT_TOKEN', 'DISCORD_ALLOW'],
              },
              {
                'channel': 'http',
                'active': true,
                'env': <String>[],
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
