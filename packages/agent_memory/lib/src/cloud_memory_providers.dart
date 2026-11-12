import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Cloud memory adapters (Hermes-style memory providers for hosted
/// services). Both speak [MemoryProvider] so [MemoryProviderRouter] fans
/// writes out and merges reads exactly like self-hosted REST backends.
///
/// Parsing is deliberately tolerant: hosted APIs evolve, so response
/// shapes are accepted as bare lists or wrapped maps and text is read
/// from the first of `memory`, `text`, or `content`. Failures surface as
/// exceptions; the router degrades retrieval instead of crashing.

/// [Mem0](https://mem0.ai) hosted memory.
///
/// - upsert  → `POST {base}/v1/memories/` with
///   `{"messages": [{"role": "user", "content": ...}], "user_id": ...}`
/// - search  → `POST {base}/v2/memories/search/` with
///   `{"query": ..., "top_k": k, "filters": {"user_id": ...}}`
/// - forget  → `DELETE {base}/v1/memories/{id}/`
class Mem0MemoryProvider implements MemoryProvider {
  Mem0MemoryProvider({
    required String apiKey,
    this.userId,
    String baseUrl = 'https://api.mem0.ai',
    HttpClient? client,
    this.timeout = const Duration(seconds: 10),
  })  : name = 'mem0',
        _base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _apiKey = apiKey,
        _client = client ?? HttpClient();

  @override
  final String name;

  /// Default user scope when a record carries no [MemoryRecord.ownerKey].
  final String? userId;
  final String _base;
  final String _apiKey;
  final HttpClient _client;
  final Duration timeout;

  String _scope(String? ownerKey) => ownerKey ?? userId ?? 'tiko-agent';

  @override
  Future<void> upsert(MemoryRecord record) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/v1/memories/'))
      ..headers.contentType = ContentType.json
      ..headers.set('Authorization', 'Token $_apiKey')
      ..write(jsonEncode({
        'messages': [
          {'role': 'user', 'content': record.text},
        ],
        'user_id': _scope(record.ownerKey),
        if (record.tags.isNotEmpty) 'metadata': {'tags': record.tags},
      }));
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    if (res.statusCode >= 400) {
      throw HttpException('mem0 upsert failed: HTTP ${res.statusCode}');
    }
  }

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/v2/memories/search/'))
      ..headers.contentType = ContentType.json
      ..headers.set('Authorization', 'Token $_apiKey')
      ..write(jsonEncode({
        'query': query,
        'top_k': k,
        'filters': {'user_id': _scope(ownerKey)},
      }));
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('mem0 search failed: HTTP ${res.statusCode}');
    }
    return parseCloudHits(jsonDecode(body), k);
  }

  @override
  Future<void> forget(String id) async {
    final req = await _client.deleteUrl(Uri.parse('$_base/v1/memories/$id/'))
      ..headers.set('Authorization', 'Token $_apiKey');
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    if (res.statusCode >= 400) {
      throw HttpException('mem0 forget failed: HTTP ${res.statusCode}');
    }
  }

  Future<void> close() async => _client.close(force: true);
}

/// Shared tolerant hit parsing for cloud adapters: accepts a bare list or
/// a wrapped map (`results`/`memories`/`records`) and reads text from the
/// first of `memory`, `text`, `content`.
List<MemoryRecord> parseCloudHits(dynamic json, int k, {String? ownerKey}) {
  List<dynamic> items;
  if (json is List) {
    items = json;
  } else if (json is Map) {
    items = [
      for (final key in const ['results', 'memories', 'records', 'data'])
        if (json[key] is List) ...(json[key] as List),
    ];
  } else {
    items = const [];
  }
  final out = <MemoryRecord>[];
  for (final raw in items.take(k)) {
    if (raw is! Map) continue;
    final text = [
      raw['memory'],
      raw['text'],
      raw['content'],
    ].whereType<String>().firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (text.isEmpty) continue;
    out.add(MemoryRecord(
      id: raw['id']?.toString() ?? '',
      text: text,
      score: (raw['score'] as num?)?.toDouble() ??
          (raw['similarity'] as num?)?.toDouble() ??
          0.0,
      ownerKey: ownerKey,
      tags: [
        for (final t in (raw['categories'] as List? ?? const []))
          if (t is String) t,
      ],
    ));
  }
  return out;
}

/// [Honcho](https://honcho.dev) pluggable memory (self-hosted or cloud).
///
/// - upsert  → `POST {base}/v1/sessions/{sessionId}/memories` with
///   `{"messages": [{"role": "user", "content": ...}]}`
/// - search  → `POST {base}/v1/sessions/{sessionId}/search` with
///   `{"query": ..., "limit": k}`
/// - forget  → `DELETE {base}/v1/memories/{id}` (best-effort)
class HonchoMemoryProvider implements MemoryProvider {
  HonchoMemoryProvider({
    required String apiKey,
    required this.sessionId,
    String baseUrl = 'https://api.honcho.dev',
    HttpClient? client,
    this.timeout = const Duration(seconds: 10),
  })  : name = 'honcho',
        _base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _apiKey = apiKey,
        _client = client ?? HttpClient();

  @override
  final String name;

  /// Honcho session the memories belong to.
  final String sessionId;
  final String _base;
  final String _apiKey;
  final HttpClient _client;
  final Duration timeout;

  @override
  Future<void> upsert(MemoryRecord record) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/v1/sessions/$sessionId/memories'))
      ..headers.contentType = ContentType.json
      ..headers.set('Authorization', 'Bearer $_apiKey')
      ..write(jsonEncode({
        'messages': [
          {'role': 'user', 'content': record.text},
        ],
      }));
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    if (res.statusCode >= 400) {
      throw HttpException('honcho upsert failed: HTTP ${res.statusCode}');
    }
  }

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/v1/sessions/$sessionId/search'))
      ..headers.contentType = ContentType.json
      ..headers.set('Authorization', 'Bearer $_apiKey')
      ..write(jsonEncode({'query': query, 'limit': k}));
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('honcho search failed: HTTP ${res.statusCode}');
    }
    return parseCloudHits(jsonDecode(body), k, ownerKey: ownerKey);
  }

  @override
  Future<void> forget(String id) async {
    final req = await _client.deleteUrl(Uri.parse('$_base/v1/memories/$id'))
      ..headers.set('Authorization', 'Bearer $_apiKey');
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    if (res.statusCode >= 400) {
      throw HttpException('honcho forget failed: HTTP ${res.statusCode}');
    }
  }

  Future<void> close() async => _client.close(force: true);
}
