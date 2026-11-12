import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;
  final mem0Store = <String, Map<String, dynamic>>{};
  final honchoStore = <String, Map<String, dynamic>>{};

  setUp(() async {
    mem0Store.clear();
    honchoStore.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/v1/memories/' && req.method == 'POST') {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final messages = json['messages'] as List;
        final content = (messages.first as Map)['content'] as String;
        final id = 'm${mem0Store.length}';
        mem0Store[id] = {
          'id': id,
          'memory': content,
          'score': 0.9,
          'categories': ['migrated'],
        };
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v2/memories/search/' && req.method == 'POST') {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final filters = json['filters'] as Map<String, dynamic>? ?? {};
        final query = (json['query'] as String? ?? '').toLowerCase();
        final userId = filters['user_id'] as String?;
        final hits = [
          for (final e in mem0Store.entries)
            if ((e.value['memory'] as String).toLowerCase().contains(query))
              {...e.value, 'user_id': userId},
        ].toList();
        req.response.write(jsonEncode(hits));
        await req.response.close();
        return;
      }
      if (req.uri.path.startsWith('/v1/memories/') &&
          req.uri.path.endsWith('/') &&
          req.method == 'DELETE') {
        final id = req.uri.pathSegments[2];
        mem0Store.remove(id);
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/sessions/s1/memories' && req.method == 'POST') {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final messages = json['messages'] as List;
        final content = (messages.first as Map)['content'] as String;
        final id = 'h${honchoStore.length}';
        honchoStore[id] = {'id': id, 'content': content};
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/sessions/s1/search' && req.method == 'POST') {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final query = (json['query'] as String? ?? '').toLowerCase();
        final hits = [
          for (final e in honchoStore.entries)
            if ((e.value['content'] as String).toLowerCase().contains(query))
              e.value,
        ].toList();
        req.response.write(jsonEncode({'memories': hits}));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('Mem0MemoryProvider upsert, search and forget round-trip', () async {
    final provider = Mem0MemoryProvider(
      apiKey: 'test-key',
      baseUrl: base,
      userId: 'user-1',
    );
    await provider.upsert(MemoryRecord(
      id: 'r1',
      text: 'pengguna suka kopi manual brew',
      ownerKey: 'user-1',
    ));
    expect(mem0Store, hasLength(1));

    final hits = await provider.search('kopi', k: 5);
    expect(hits, hasLength(1));
    expect(hits.first.text, 'pengguna suka kopi manual brew');
    expect(hits.first.tags, contains('migrated'));

    await provider.forget(hits.first.id);
    expect(mem0Store, isEmpty);
    await provider.close();
  });

  test('HonchoMemoryProvider upsert and search', () async {
    final provider = HonchoMemoryProvider(
      apiKey: 'test-key',
      sessionId: 's1',
      baseUrl: base,
    );
    await provider.upsert(MemoryRecord(id: 'r2', text: 'deploy tiap jumat'));
    final hits = await provider.search('deploy', k: 5);
    expect(hits, hasLength(1));
    expect(hits.first.text, 'deploy tiap jumat');
    await provider.close();
  });

  test('parseCloudHits tolerates wrapped and bare-list shapes', () {
    final fromMap = parseCloudHits({
      'results': [
        {'memory': 'halo', 'score': 0.5},
      ],
    }, 5);
    expect(fromMap.single.text, 'halo');
    final fromList = parseCloudHits([
      {'text': 'dunia'},
    ], 5);
    expect(fromList.single.text, 'dunia');
    expect(parseCloudHits({'other': []}, 5), isEmpty);
  });
}
