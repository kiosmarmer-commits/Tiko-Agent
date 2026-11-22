import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Surface page (Fase E3/E4) di atas fake agentd: daftar, detail, dan
/// penghapusan snapshot surface A2UI via `/v1/surfaces*`.
void main() {
  group('repository surfaces', () {
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

    test('surfaces() membaca daftar + meneruskan filter session_key', () async {
      final list = await repo.surfaces(sessionKey: 'web:abc');
      expect(list, hasLength(1));
      expect(list.single['surfaceId'], 's-ui-1');
      expect(list.single['sessionKey'], 'web:abc');
      expect(fake.lastSessionFilter, 'web:abc');
    });

    test('surface() mengembalikan body lengkap', () async {
      final doc = await repo.surface('s-ui-1');
      expect(doc, isNotNull);
      expect(doc!['catalogId'], 'tiko.basic.v1');
      expect((doc['components'] as List), isNotEmpty);
    });

    test('surface() mengembalikan null pada 404', () async {
      expect(await repo.surface('ghost'), isNull);
    });

    test('deleteSurface() true pada 200 ok dan false pada 404', () async {
      expect(await repo.deleteSurface('s-ui-1'), isTrue);
      expect(fake.deletedIds, ['s-ui-1']);
      expect(await repo.deleteSurface('ghost'), isFalse);
    });

    test('bearer tetap di header', () async {
      await repo.surfaces();
      expect(fake.lastAuthHeader, 'Bearer t');
    });
  });
}

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';
  String lastSessionFilter = '';
  final List<String> deletedIds = [];

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final method = req.method;
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        final auth = req.headers.value('authorization') ?? '';
        if (path.startsWith('/v1/surfaces')) lastAuthHeader = auth;
        final session = req.uri.queryParameters['session_key'];
        if (session != null) lastSessionFilter = session;

        if (path == '/v1/surfaces' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'surfaces': [
              {
                'surfaceId': 's-ui-1',
                'sessionKey': 'web:abc',
                'updatedAt': '2026-11-22T10:00:00.000Z',
              },
            ],
          }));
        } else if (path == '/v1/surfaces/s-ui-1' && method == 'GET') {
          req.response.write(jsonEncode(<String, dynamic>{
            'surfaceId': 's-ui-1',
            'sessionKey': 'web:abc',
            'updatedAt': '2026-11-22T10:00:00.000Z',
            'catalogId': 'tiko.basic.v1',
            'components': [
              {'id': 'root', 'component': 'Divider'},
            ],
            'dataModel': <String, dynamic>{},
          }));
        } else if (path == '/v1/surfaces/s-ui-1' && method == 'DELETE') {
          deletedIds.add(path.split('/').last);
          req.response.write(jsonEncode(<String, dynamic>{'ok': true, 'id': 's-ui-1'}));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'surface tidak ditemukan',
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
