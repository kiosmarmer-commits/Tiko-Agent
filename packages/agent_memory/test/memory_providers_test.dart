import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

class LocalStore implements MemoryProvider {
  final Map<String, MemoryRecord> store = {};

  @override
  String get name => 'local';

  @override
  Future<void> upsert(MemoryRecord record) async =>
      store[record.id] = record;

  @override
  Future<List<MemoryRecord>> search(String query,
      {int k = 8, String? ownerKey}) async {
    final hits = store.values
        .where((r) => ownerKey == null || r.ownerKey == ownerKey)
        .where((r) => r.text.toLowerCase().contains(query.toLowerCase()))
        .take(k)
        .toList();
    return hits;
  }

  @override
  Future<void> forget(String id) async => store.remove(id);
}

/// Minimal stub of an external memory REST backend, bound to loopback.
Future<HttpServer> startStubServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decodeStream(req);
    if (req.method == 'POST' && req.uri.path == '/memories') {
      final record = MemoryRecord.fromJson(
          jsonDecode(body) as Map<String, dynamic>);
      stubStore[record.id] = record;
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && req.uri.path == '/memories/search') {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final query = (json['query'] as String? ?? '').toLowerCase();
      final hits = stubStore.values
          .where((r) => r.text.toLowerCase().contains(query))
          .map((r) => r.toJson())
          .toList();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'records': hits}));
      await req.response.close();
      return;
    }
    if (req.method == 'DELETE' && req.uri.path.startsWith('/memories/')) {
      final id = req.uri.path.split('/').last;
      stubStore.remove(id);
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  });
  return server;
}

final Map<String, MemoryRecord> stubStore = {};

void main() {
  setUp(() => stubStore.clear());

  test('HttpMemoryProvider upsert, search and forget against REST stub',
      () async {
    final server = await startStubServer();
    final provider = HttpMemoryProvider(
      config: HttpMemoryProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}'),
      name: 'stub',
    );
    await provider.upsert(const MemoryRecord(
        id: 'x1', text: 'user suka kopi', score: 0.9, ownerKey: 'u1'));
    expect(stubStore, containsPair('x1', isNotNull));

    final hits = await provider.search('kopi');
    expect(hits, hasLength(1));
    expect(hits.single.id, 'x1');

    await provider.forget('x1');
    expect(stubStore, isEmpty);
    await provider.close();
    await server.close(force: true);
  });

  test('HttpMemoryProvider retries then surfaces failures', () async {
    final provider = HttpMemoryProvider(
      config: const HttpMemoryProviderConfig(
        baseUrl: 'http://127.0.0.1:1',
        maxRetries: 1,
        retryDelay: Duration(milliseconds: 10),
      ),
      name: 'dead',
    );
    await expectLater(
      provider.upsert(const MemoryRecord(id: 'a', text: 'x')),
      throwsA(isA<Exception>()),
    );
    await provider.close();
  });

  test('router fans out writes and merges reads with weights', () async {
    final server = await startStubServer();
    final external = HttpMemoryProvider(
      config: HttpMemoryProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}'),
      name: 'stub',
    );
    final local = LocalStore();
    final router = MemoryProviderRouter(
      local: local,
      external: [external],
      weights: {'stub': 2.0},
    );

    await router.upsert(const MemoryRecord(
        id: 'l1', text: 'fakta lokal', score: 0.5));
    await router.upsert(const MemoryRecord(
        id: 'e1', text: 'fakta eksternal', score: 0.5));

    expect(local.store.keys, contains('e1'));
    expect(stubStore.keys, contains('l1'));

    final hits = await router.search('fakta');
    expect(hits, hasLength(2));
    expect(hits.first.id, 'e1');

    await external.close();
    await server.close(force: true);
  });

  test('router dedupes by owner+text keeping the best score', () async {
    final server = await startStubServer();
    final external = HttpMemoryProvider(
      config: HttpMemoryProviderConfig(
          baseUrl: 'http://127.0.0.1:${server.port}'),
      name: 'stub',
    );
    final local = LocalStore();
    final router = MemoryProviderRouter(local: local, external: [external]);

    await router.upsert(const MemoryRecord(
        id: 'dup', text: 'entitas sama', score: 0.4));
    stubStore['dup-remote'] = const MemoryRecord(
        id: 'dup-remote', text: 'entitas sama', score: 0.9);

    final hits = await router.search('entitas');
    expect(hits, hasLength(1));
    expect(hits.single.score, 0.9);

    await external.close();
    await server.close(force: true);
  });

  test('fallback policy keeps local hits when they are enough', () async {
    final local = LocalStore();
    final router = MemoryProviderRouter(
      local: local,
      external: [_DeadProvider()],
      mergePolicy: MemoryMergePolicy.fallback,
      localFallbackThreshold: 2,
    );
    await router.upsert(const MemoryRecord(id: '1', text: 'satu'));
    await router.upsert(const MemoryRecord(id: '2', text: 'dua'));
    final hits = await router.search('');
    expect(hits, hasLength(2));
  });

  test('provider failures degrade retrieval, never crash the router',
      () async {
    final router = MemoryProviderRouter(
      local: LocalStore(),
      external: [_DeadProvider()],
    );
    await router.upsert(const MemoryRecord(id: '1', text: 'satu'));
    final hits = await router.search('satu');
    expect(hits, hasLength(1));
  });

  test('upsert throws only when every provider fails', () async {
    final router = MemoryProviderRouter(local: _DeadProvider());
    await expectLater(
      router.upsert(const MemoryRecord(id: '1', text: 'satu')),
      throwsA(isA<HttpException>()),
    );
  });
}

class _DeadProvider implements MemoryProvider {
  @override
  String get name => 'dead';

  @override
  Future<void> upsert(MemoryRecord record) async =>
      throw const HttpException('down');

  @override
  Future<List<MemoryRecord>> search(String query,
          {int k = 8, String? ownerKey}) async =>
      throw const HttpException('down');

  @override
  Future<void> forget(String id) async => throw const HttpException('down');
}
