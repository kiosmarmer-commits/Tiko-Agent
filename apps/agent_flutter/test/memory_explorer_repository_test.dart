import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Memory Explorer (GUI-P1-12) repository di atas fake agentd: kurasi,
/// lapisan (list/add/delete) dan sumber RAG.
void main() {
  group('GUI-P1-12: repository memory explorer', () {
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

    test('curatedMemory() typed + path + bearer', () async {
      final info = await repo.curatedMemory();
      expect(info.memory.text, '# Fakta');
      expect(info.memory.chars, '# Fakta'.length);
      expect(info.user.text, 'Suka teh');
      expect(info.budget, 3575);
      expect(info.used, '# Fakta'.length + 'Suka teh'.length);
      expect(fake.lastPath, '/v1/memory/curated');
      expect(fake.lastAuthHeader, 'Bearer t');
    });

    test('setCuratedMemory PATCH body + refresh snapshot', () async {
      final info = await repo.setCuratedMemory(file: 'user', text: 'baru');
      expect(fake.sawPatchCurated, isTrue);
      expect(fake.lastBody['file'], 'user');
      expect(fake.lastBody['text'], 'baru');
      expect(info.user.text, 'baru');
    });

    test('layered() tanpa query + dengan query + limit', () async {
      final snap = await repo.layered();
      expect(snap.entries, hasLength(2));
      expect(snap.stats['semantic']?.count, 1);
      expect(snap.entries.first.tags, contains('tiko'));
      expect(snap.total, 2);
      expect(fake.lastPath, '/v1/memory/layers');

      fake.lastMethod = '';
      final queried =
          await repo.layered(query: 'prosedur build', limit: 25);
      expect(queried.entries.first.layer, 'procedural');
      expect(queried.entries.first.text, 'Prosedur build Tiko');
      expect(fake.lastQuery, 'q=prosedur+build&limit=25');
    });

    test('addLayerEntry POST 201 + deleteLayerEntry OK/404', () async {
      final entry = await repo.addLayerEntry({
        'layer': 'semantic',
        'text': 'Sandbox isolasi',
        'importance': 0.8,
        'tags': ['infra'],
      });
      expect(fake.lastMethod, 'POST');
      expect(entry.id, 'lay-3');
      expect(entry.layer, 'semantic');
      expect(entry.importance, closeTo(0.8, 0.001));

      expect(await repo.deleteLayerEntry('lay-3'), isTrue);
      expect(fake.lastMethod, 'DELETE');
      expect(fake.lastPath, '/v1/memory/layers/lay-3');

      fake.nextErrorCode = 404;
      fake.nextErrorCodeName = 'not_found';
      expect(await repo.deleteLayerEntry('lay-x'), isFalse);
    });

    test('ragSources() typed + 501 typed untuk daemon lama', () async {
      final rag = await repo.ragSources();
      expect(rag.chunkCount, 3);
      expect(rag.docs.first.docId, 'handbook.md');
      expect(rag.docs.first.chunks, 2);
      expect(rag.docs.first.preview, isNotEmpty);
      expect(rag.truncated, isFalse);

      fake.nextErrorCode = 501;
      fake.nextErrorCodeName = 'not_implemented';
      try {
        await repo.ragSources();
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
  String lastQuery = '';
  String lastMethod = '';
  bool sawPatchCurated = false;
  Map<String, dynamic> lastBody = {};
  int nextErrorCode = 0;
  String? nextErrorCodeName;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        lastPath = req.uri.path;
        lastQuery = req.uri.query;
        lastMethod = req.method;
        lastAuthHeader = req.headers.value('authorization') ?? '';
        final body =
            await utf8.decoder.bind(req).join().then((s) => s.isEmpty ? '' : s);
        if (body.isNotEmpty) {
          try {
            lastBody =
                Map<String, dynamic>.from(jsonDecode(body) as Map);
          } catch (_) {
            lastBody = {};
          }
        }
        if (req.method == 'PATCH' && req.uri.path == '/v1/memory/curated') {
          sawPatchCurated = true;
          if (lastBody['file'] == 'user' && lastBody['text'] is String) {
            userText = '${lastBody['text']}';
          }
        }
        final res = req.response..headers.contentType = ContentType.json;
        if (nextErrorCode != 0) {
          res.statusCode = nextErrorCode;
          res.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': nextErrorCodeName ?? 'server',
            'error': 'not configured',
            'retryable': false,
          }));
          await res.close();
          continue;
        }
        final payload = switch ((req.method, req.uri.path)) {
          ('PATCH', '/v1/memory/curated') => _writeLastBody,
          ('POST', '/v1/memory/layers') => _addedEntry,
          _ => _payloadFor(req),
        };
        if (req.method == 'POST' && req.uri.path == '/v1/memory/layers') {
          res.statusCode = 201;
        }
        res.write(jsonEncode(payload));
        await res.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  String userText = 'Suka teh';

  Map<String, dynamic> get _writeLastBody => lastBody['file'] == 'user'
      ? <String, dynamic>{
          'ok': true,
          'used': '# Fakta'.length + userText.length,
          'budget': 3575,
        }
      : <String, dynamic>{'ok': true, 'used': 10, 'budget': 3575};

  Map<String, dynamic> get _addedEntry => <String, dynamic>{
        'id': 'lay-3',
        'layer': '${lastBody['layer'] ?? 'semantic'}',
        'text': '${lastBody['text'] ?? ''}',
        'importance': lastBody['importance'] ?? 0.5,
        'tags': [
          for (final t in lastBody['tags'] as List? ?? const []) '$t',
        ],
        'access_count': 0,
        'created_at': '2026-11-18T13:10:00.000Z',
        'last_accessed_at': '2026-11-18T13:10:00.000Z',
        'owner_key': '',
        'source_session': '',
      };

  Map<String, dynamic> _payloadFor(HttpRequest req) {
    return switch (req.uri.path) {
      '/v1/memory/curated' => {
          ..._curatedPayload,
          'user': {'text': userText, 'chars': userText.length},
        },
      '/v1/memory/layers' =>
        lastQuery.isEmpty ? _layersPayload : _queriedLayersPayload,
      '/v1/memory/rag' => _ragPayload,
      _ when req.uri.path.startsWith('/v1/memory/layers/') =>
        {'ok': true, 'id': req.uri.path.split('/').last},
      _ => const <String, dynamic>{},
    };
  }

  Future<void> close() async => _server?.close();

  static final _curatedPayload = <String, dynamic>{
    'memory': {'text': '# Fakta', 'chars': '# Fakta'.length},
    'user': {'text': 'Suka teh', 'chars': 'Suka teh'.length},
    'budget': 3575,
    'used': '# Fakta'.length + 'Suka teh'.length,
  };

  static final _layersPayload = <String, dynamic>{
    'stats': {'semantic': {'count': 1, 'avg_score': 0.5}},
    'entries': [
      {
        'id': 'lay-1',
        'layer': 'semantic',
        'text': 'Tiko agent ditulis Dart',
        'importance': 0.5,
        'tags': ['tiko', 'dart'],
        'access_count': 2,
        'created_at': '2026-11-18T13:00:00.000Z',
        'last_accessed_at': '2026-11-18T13:05:00.000Z',
        'owner_key': '',
        'source_session': '',
      },
      {
        'id': 'lay-2',
        'layer': 'procedural',
        'text': 'Build dengan bootstrap.sh',
        'importance': 0.7,
        'tags': [],
        'access_count': 0,
        'created_at': '2026-11-18T12:00:00.000Z',
        'last_accessed_at': '2026-11-18T12:00:00.000Z',
        'owner_key': 'admin',
        'source_session': 'web:1',
      },
    ],
    'total': 2,
    'truncated': false,
  };

  static final _queriedLayersPayload = <String, dynamic>{
    'stats': {
      'procedural': {'count': 1, 'avg_score': 0.7},
    },
    'entries': [
      {
        'id': 'lay-2',
        'layer': 'procedural',
        'text': 'Prosedur build Tiko',
        'importance': 0.7,
        'tags': ['build'],
        'access_count': 1,
        'created_at': '2026-11-18T12:00:00.000Z',
        'last_accessed_at': '2026-11-18T12:00:00.000Z',
        'owner_key': '',
        'source_session': '',
      },
    ],
    'total': 1,
    'truncated': false,
  };

  static final _ragPayload = <String, dynamic>{
    'chunk_count': 3,
    'docs': [
      {
        'doc_id': 'handbook.md',
        'chunks': 2,
        'chars': 900,
        'preview': 'Panduan build\u2026',
      },
      {
        'doc_id': 'faq.md',
        'chunks': 1,
        'chars': 240,
        'preview': 'Pertanyaan umum\u2026',
      },
    ],
    'truncated': false,
  };
}
