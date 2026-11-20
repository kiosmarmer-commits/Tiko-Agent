import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// RetainDB memory provider adapter.
class RetainDbMemoryProvider implements MemoryProvider {
  RetainDbMemoryProvider({
    required this.apiKey,
    required this.embedder,
    this.baseUrl = 'https://api.retaindb.com/v1',
    this.collectionName = 'tiko_agent',
    this.embeddingDimension = 1536,
    this.httpClient,
    this.timeout = const Duration(seconds: 30),
  });

  final String apiKey;
  final String baseUrl;
  final String collectionName;
  final int embeddingDimension;
  final http.Client? httpClient;
  final Duration timeout;
  final Future<List<double>> Function(String text) embedder;

  @override
  String get name => 'retaindb';

  Future<void> _ensureCollection() async {
    final client = httpClient ?? http.Client();
    try {
      final uri = Uri.parse('$baseUrl/collections/$collectionName');
      final res = await client
          .get(uri, headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          })
          .timeout(timeout);

      if (res.statusCode == 404) {
        await client
            .post(Uri.parse('$baseUrl/collections'), headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            }, body: jsonEncode({
              'name': collectionName,
              'dimension': embeddingDimension,
            }))
            .timeout(timeout);
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> upsert(MemoryRecord record) async {
    final client = httpClient ?? http.Client();
    try {
      await _ensureCollection();
      final embedding = await embedder(record.text);
      final uri = Uri.parse('$baseUrl/collections/$collectionName/vectors');
      final res = await client
          .post(uri, headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          }, body: jsonEncode({
            'id': record.id,
            'values': embedding,
            'metadata': {
              'text': record.text,
              'owner_key': record.ownerKey,
              'tags': record.tags,
              'created_at': record.createdAt?.toIso8601String(),
            },
          }))
          .timeout(timeout);

      if (res.statusCode >= 400) {
        throw StateError('RetainDB upsert failed: HTTP ${res.statusCode}');
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<List<MemoryRecord>> search(String query, {int k = 8, String? ownerKey}) async {
    final client = httpClient ?? http.Client();
    try {
      final queryEmbedding = await embedder(query);
      final uri = Uri.parse('$baseUrl/collections/$collectionName/vectors/query');
      final filter = ownerKey != null ? {'owner_key': ownerKey} : null;
      final body = <String, dynamic>{
        'vector': queryEmbedding,
        'limit': k,
        if (filter != null) 'filter': filter,
      };
      final res = await client
          .post(uri, headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          }, body: jsonEncode(body))
          .timeout(timeout);

      if (res.statusCode >= 400) {
        throw StateError('RetainDB search failed: HTTP ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>? ?? [];
      return results.map((r) {
        final map = r as Map<String, dynamic>;
        final metadata = map['metadata'] as Map<String, dynamic>? ?? {};
        return MemoryRecord(
          id: map['id'] as String? ?? '',
          text: metadata['text'] as String? ?? '',
          ownerKey: metadata['owner_key'] as String?,
          tags: (metadata['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ?? [],
          createdAt: metadata['created_at'] != null
              ? DateTime.tryParse(metadata['created_at'] as String? ?? '')
              : null,
          score: (map['score'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> forget(String id) async {
    final client = httpClient ?? http.Client();
    try {
      final uri = Uri.parse('$baseUrl/collections/$collectionName/vectors/$id');
      final res = await client
          .delete(uri, headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(timeout);
      if (res.statusCode >= 400) {
        throw StateError('RetainDB forget failed: HTTP ${res.statusCode}');
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
