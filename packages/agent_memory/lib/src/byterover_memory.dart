import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// ByteRover memory provider adapter.
///
/// ByteRover is a vector database for AI applications.
/// This implements the MemoryProvider interface.
///
/// API Documentation: https://byterover.com/docs
class ByteRoverMemoryProvider implements MemoryProvider {
  ByteRoverMemoryProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.byterover.com/v1',
    this.namespace = 'tiko_agent',
    this.httpClient,
    this.timeout = const Duration(seconds: 30),
    this.embedder,
  });

  final String apiKey;
  final String baseUrl;
  final String namespace;
  final http.Client? httpClient;
  final Duration timeout;

  /// Vectorises record text. MemoryRecord carries no embedding field, so a
  /// vector database adapter must obtain the vector itself, matching the
  /// embedder pattern used by RagPipeline.
  final Future<List<double>> Function(String text)? embedder;

  @override
  String get name => 'byterover';

  @override
  Future<void> upsert(MemoryRecord record) async {
    final client = httpClient ?? http.Client();
    try {
      final embed = embedder;
      if (embed == null) {
        throw StateError(
          'ByteRoverMemoryProvider requires an embedder to vectorise text',
        );
      }
      final embedding = await embed(record.text);
      if (embedding.isEmpty) {
        throw ArgumentError('embedder returned an empty vector');
      }

      final uri = Uri.parse('$baseUrl/namespaces/$namespace/vectors');
      final res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'id': record.id,
              'values': embedding,
              'metadata': {
                'text': record.text,
                'owner_key': record.ownerKey,
                'tags': record.tags,
                'created_at': record.createdAt?.toIso8601String(),
              },
            }),
          )
          .timeout(timeout);

      if (res.statusCode >= 400) {
        throw StateError('ByteRover upsert failed: HTTP ${res.statusCode}');
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      // Build filter for ownerKey if provided
      final filter = ownerKey != null ? {'owner_key': ownerKey} : null;

      final uri = Uri.parse('$baseUrl/namespaces/$namespace/vectors/query');
      final res = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'limit': k,
              if (filter != null) 'filter': filter,
            }),
          )
          .timeout(timeout);

      if (res.statusCode >= 400) {
        throw StateError('ByteRover search failed: HTTP ${res.statusCode}');
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
          tags: (metadata['tags'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ?? [],
          createdAt: metadata['created_at'] != null
              ? DateTime.tryParse(metadata['created_at'] as String? ?? '')
              : null,
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
      final uri = Uri.parse('$baseUrl/namespaces/$namespace/vectors/$id');
      final res = await client
          .delete(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(timeout);

      if (res.statusCode >= 400) {
        throw StateError('ByteRover forget failed: HTTP ${res.statusCode}');
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
