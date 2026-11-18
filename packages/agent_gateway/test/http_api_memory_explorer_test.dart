import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// GUI-P1-12: Memory Explorer — kurasi (GET/PATCH), lapisan (GET read,
/// POST add, DELETE hapus), sumber RAG; validasi typed 400/404/501.
void main() {
  late HttpApiServer server;
  late HttpApiServer bare;
  late Map<String, dynamic> lastCuratedPatch;
  late Map<String, dynamic> lastLayersFilter;
  late Map<String, dynamic> lastLayerAdd;
  late String? lastDeletedId;

  setUp(() async {
    lastCuratedPatch = {};
    lastLayersFilter = {};
    lastLayerAdd = {};
    lastDeletedId = null;
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
      memoryCuratedProvider: () async => {
        'memory': {'text': 'pemilik: Andi', 'chars': 13},
        'user': {'text': '', 'chars': 0},
        'budget': 3575,
        'used': 13,
      },
      memoryCuratedSetProvider: (body) async {
        lastCuratedPatch = body;
        return {'ok': true, 'used': 20, 'budget': 3575};
      },
      memoryLayersProvider: (filters) async {
        lastLayersFilter = filters;
        return {
          'stats': {
            'semantic': {'count': 1, 'avg_score': 0.9},
            'episodic': {'count': 1, 'avg_score': 0.5},
            'procedural': {'count': 0, 'avg_score': 0.0},
          },
          'entries': [
            {
              'id': 'm1',
              'layer': 'semantic',
              'text': 'deploy pakai release.sh',
              'importance': 0.8,
              'tags': ['deploy'],
              'access_count': 2,
              'created_at': '2026-11-18T13:00:00.000Z',
              'last_accessed_at': '2026-11-18T13:05:00.000Z',
              'owner_key': 'admin',
              'source_session': null,
            },
          ],
          'total': 2,
          'truncated': true,
        };
      },
      memoryLayerAddProvider: (body) async {
        lastLayerAdd = body;
        return {
          'id': 'm9',
          'layer': body['layer'],
          'text': body['text'],
          'importance': body['importance'],
          'tags': body['tags'],
          'created_at': '2026-11-18T14:00:00.000Z',
        };
      },
      memoryLayerDeleteProvider: (id) async {
        lastDeletedId = id;
        return id == 'm1';
      },
      memoryRagProvider: () async => {
        'chunk_count': 2,
        'docs': [
          {'doc_id': 'doc-readme', 'chunks': 1, 'chars': 33, 'preview': 'Tiko…'},
        ],
        'truncated': false,
      },
    );
    await server.start();
    bare = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await bare.start();
  });

  tearDown(() async {
    await server.stop();
    await bare.stop();
  });

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    HttpApiServer? target,
    Object? body,
  }) async {
    final client = HttpClient();
    final srv = target ?? server;
    try {
      final uri = Uri.parse('http://127.0.0.1:${srv.boundPort}$path');
      final request = await client.openUrl(method, uri);
      request.headers.set(
          'authorization', 'Bearer manager-token-0123456789abcdef');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return {
        'status': response.statusCode,
        'body': text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>,
      };
    } finally {
      client.close(force: true);
    }
  }

  test('kurasi: GET + PATCH valid; PATCH invalid → 400', () async {
    final g = await send('GET', '/v1/memory/curated');
    expect(g['status'], 200);
    expect((g['body']['memory'] as Map)['text'], 'pemilik: Andi');
    expect(g['body']['budget'], 3575);

    final p = await send('PATCH', '/v1/memory/curated',
        body: {'file': 'user', 'text': 'umur 12'});
    expect(p['status'], 200);
    expect(p['body']['ok'], isTrue);
    expect(lastCuratedPatch, {'file': 'user', 'text': 'umur 12'});

    expect(
        (await send('PATCH', '/v1/memory/curated', body: {
          'file': 'lain',
          'text': 'x'
        }))['status'],
        400);
    expect(
        (await send('PATCH', '/v1/memory/curated', body: {
          'file': 'memory',
          'text': 5
        }))['status'],
        400);
    expect(
        (await send('PATCH', '/v1/memory/curated',
            body: 'bukan-json'))['status'],
        400);
  });

  test('lapisan: GET (filter q/limit) + POST 201 + DELETE; invalid → 400', () async {
    final g = await send('GET', '/v1/memory/layers');
    expect(g['status'], 200);
    expect(lastLayersFilter['q'], isNull);
    expect(g['body']['total'], 2);
    expect((g['body']['entries'] as List).first['layer'], 'semantic');

    await send('GET', '/v1/memory/layers?q=deploy&limit=5');
    expect(lastLayersFilter['q'], 'deploy');
    expect(lastLayersFilter['limit'], 5);

    final bad = await send('GET', '/v1/memory/layers?limit=banyak');
    expect(bad['status'], 400);

    final add = await send('POST', '/v1/memory/layers', body: {
      'layer': 'episodic',
      'text': 'catatan pagi',
      'importance': 0.4,
      'tags': ['rutin', ''],
    });
    expect(add['status'], 201);
    expect(add['body']['id'], 'm9');
    expect(lastLayerAdd['tags'], ['rutin']);
    expect(lastLayerAdd['importance'], 0.4);

    expect(
        (await send('POST', '/v1/memory/layers',
            body: {'layer': 'bos', 'text': 'x'}))['status'],
        400);
    expect(
        (await send('POST', '/v1/memory/layers',
            body: {'layer': 'episodic', 'text': '  '}))['status'],
        400);
    expect(
        (await send('POST', '/v1/memory/layers',
            body: {'layer': 'episodic', 'text': 'x', 'importance': 5}))['status'],
        400);
    expect(
        (await send('POST', '/v1/memory/layers',
            body: {'layer': 'episodic', 'text': 'x', 'tags': 'bukan-array'}))['status'],
        400);

    final del = await send('DELETE', '/v1/memory/layers/m1');
    expect(del['status'], 200);
    expect(lastDeletedId, 'm1');
    expect((await send('DELETE', '/v1/memory/layers/m-nope'))['status'], 404);
  });

  test('rag: GET passthrough; bare daemon 501; method salah 404', () async {
    final r = await send('GET', '/v1/memory/rag');
    expect(r['status'], 200);
    expect(r['body']['chunk_count'], 2);
    expect((r['body']['docs'] as List).first['doc_id'], 'doc-readme');

    final client = HttpClient();
    final uri =
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/memory/rag');
    final request = await client.openUrl('GET', uri);
    final response = await request.close();
    expect(response.statusCode, 401);
    client.close(force: true);

    expect((await send('GET', '/v1/memory/rag', target: bare))['status'], 501);
    expect(
        (await send('GET', '/v1/memory/layers', target: bare))['status'], 501);
    expect(
        (await send('GET', '/v1/memory/curated', target: bare))['status'], 501);
    expect((await send('POST', '/v1/memory/rag'))['status'], 404);
    expect((await send('POST', '/v1/memory/curated'))['status'], 404);
  });
}
