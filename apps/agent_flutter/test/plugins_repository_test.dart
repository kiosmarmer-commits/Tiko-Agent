import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plugin & Tools Manager (GUI-P1-06) di atas fake agentd: snapshot plugin +
/// consent, katalog tool registry, dan status server MCP (parity /plugin).
void main() {
  group('GUI-P1-06: repository plugins', () {
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

    test('pluginsTools() mengembalikan snapshot typed lengkap', () async {
      final snap = await repo.pluginsTools();
      expect(snap.plugins.length, 2);
      expect(snap.plugins[0].id, 'memory-secretary');
      expect(snap.plugins[0].registered, isTrue);
      expect(snap.plugins[0].granted, ['memory.write']);
      expect(snap.plugins[1].pending, isTrue);
      expect(snap.plugins[1].requested, ['tools.register', 'network.fetch']);
      expect(snap.tools.length, 2);
      expect(snap.tools[0].name, 'read_file');
      expect(snap.tools[0].risk, 'low');
      expect(snap.tools[1].risk, 'critical');
      expect(snap.mcp?.started, isTrue);
      expect(snap.mcp?.configured.single.id, 'fs-mcp');
      expect(snap.mcp?.loader.single['status'], 'ready');
      expect(snap.events.single.plugin, 'weather-pro');
    });

    test('setPluginConsent() POST body plugin + action', () async {
      final message = await repo.setPluginConsent('weather-pro', 'grant');
      expect(fake.lastConsentPath, '/v1/plugins/consent');
      expect(fake.lastConsentBody, {'plugin': 'weather-pro', 'action': 'grant'});
      expect(message, contains('disetujui'));
    });

    test('revoke consent mengembalikan pesan server', () async {
      final message = await repo.setPluginConsent('memory-secretary', 'revoke');
      expect(message, contains('dicabut'));
      expect(fake.consents.containsKey('memory-secretary'), isFalse);
    });

    test('plugin tidak dikenal 404 \u2192 ApiError notFound', () async {
      try {
        await repo.setPluginConsent('ghost', 'grant');
        fail('harusnya melempar');
      } on ApiError catch (e) {
        expect(e.code, ApiErrorCode.notFound);
      }
    });

    test('bearer tetap di header', () async {
      await repo.pluginsTools();
      expect(fake.lastAuthHeader, 'Bearer t');
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  Map<String, dynamic> lastConsentBody = {};
  String lastConsentPath = '';
  String lastAuthHeader = '';
  Map<String, String> consents = {'memory-secretary': 'memory.write'};

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/plugins')) lastAuthHeader = auth;

        if (path == '/v1/plugins' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'plugins': [
              {
                'id': 'memory-secretary',
                'registered': true,
                'pending': false,
                'granted': ['memory.write'],
                'requested': <String>[],
              },
              {
                'id': 'weather-pro',
                'registered': false,
                'pending': true,
                'granted': <String>[],
                'requested': ['tools.register', 'network.fetch'],
              },
            ],
            'tools': [
              {
                'name': 'read_file',
                'description': 'Baca file',
                'risk': 'low',
                'timeout_sec': 30,
                'parallel_safe': true,
              },
              {
                'name': 'shell_exec',
                'description': 'Eksekusi shell',
                'risk': 'critical',
                'timeout_sec': 60,
                'parallel_safe': false,
              },
            ],
            'events': [
              {
                'plugin': 'weather-pro',
                'hook': 'onSessionStart',
                'detail': 'consent required',
                'error': null,
                'at': '2026-11-18T00:00:00.000Z',
              },
            ],
            'mcp': {
              'started': true,
              'configured': [
                {
                  'id': 'fs-mcp',
                  'type': 'stdio',
                  'enabled': true,
                  'risk': 'medium',
                  'command': '/usr/bin/fs-mcp',
                  'allow': <String>[],
                },
              ],
              'loader': [
                {
                  'id': 'fs-mcp',
                  'status': 'ready',
                  'transport': 'stdio',
                  'tools': 2,
                },
              ],
            },
          }));
        } else if (path == '/v1/plugins/consent' && method == 'POST') {
          lastConsentPath = path;
          lastConsentBody = Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(req).join()) as Map);
          final plugin = '${lastConsentBody['plugin']}';
          if (plugin != 'weather-pro' && plugin != 'memory-secretary') {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': false,
              'code': 'not_found',
              'error': 'Plugin "$plugin" tidak dikenal.',
              'retryable': false,
            }));
          } else if (lastConsentBody['action'] == 'grant') {
            consents[plugin] = 'tools.register,network.fetch';
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'message': 'Plugin "$plugin" disetujui dan terdaftar '
                  '(tools.register, network.fetch).',
            }));
          } else {
            consents.remove(plugin);
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': true,
              'message': 'Consent plugin "$plugin" dicabut; '
                  'plugin dibatalkan registrasinya.',
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
