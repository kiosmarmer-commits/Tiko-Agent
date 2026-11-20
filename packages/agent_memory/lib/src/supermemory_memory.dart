import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// SuperMemory provider for AI agent memory.
///
/// SuperMemory is a memory plugin that provides long-term memory
/// storage with semantic search capabilities for AI agents.
///
/// Configuration:
/// - apiKey: SuperMemory API key (required)
/// - baseUrl: SuperMemory API base URL (default: https://api.supermemory.ai)
/// - timeout: Request timeout (default: 30 seconds)
/// - sessionId: Optional session ID for scoping memories
class SuperMemoryProvider implements MemoryProvider {
  SuperMemoryProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.supermemory.ai',
    this.timeout = const Duration(seconds: 30),
    this.sessionId,
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final String? sessionId;

  @override
  String get name => 'supermemory';

  @override
  Future<void> upsert(MemoryRecord record) async {
    try {
      final requestBody = {
        'session_id': sessionId ?? record.ownerKey,
        'key': record.id,
        'value': record.text,
        'metadata': {
          'tags': record.tags,
          'created_at': record.createdAt?.toIso8601String(),
        },
        'timestamp': record.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/memory/upsert',
        requestBody,
      );
    } catch (e) {
      throw StateError('Failed to upsert memory: ${e.toString()}');
    }
  }

  @override
  Future<List<MemoryRecord>> search(
    String query, {
    int k = 8,
    String? ownerKey,
  }) async {
    try {
      final requestBody = {
        'session_id': ownerKey ?? sessionId,
        'query': query,
        'limit': k,
      };

      final response = await _makeRequest(
        'POST',
        '/v1/memory/search',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>? ?? [];

      return results.map((item) {
        final map = item as Map<String, dynamic>;
        final metadata = map['metadata'] as Map<String, dynamic>? ?? {};
        return MemoryRecord(
          id: map['key'] as String? ?? '',
          text: map['value'] as String? ?? '',
          ownerKey: map['session_id'] as String?,
          tags: (metadata['tags'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ?? [],
          createdAt: metadata['created_at'] != null
              ? DateTime.tryParse(metadata['created_at'] as String)
              : null,
          score: (map['score'] as num?)?.toDouble() ?? 0.0,
        );
      }).toList();
    } catch (e) {
      throw StateError('Failed to search memory: ${e.toString()}');
    }
  }

  @override
  Future<void> forget(String id) async {
    try {
      final requestBody = {
        'session_id': sessionId,
        'key': id,
      };

      await _makeRequest(
        'POST',
        '/v1/memory/forget',
        requestBody,
      );
    } catch (e) {
      throw StateError('Failed to forget memory: ${e.toString()}');
    }
  }

  Future<http.Response> _makeRequest(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    final client = http.Client();
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers)
        ..body = body != null ? jsonEncode(body) : '';

      final response = await client.send(request).timeout(timeout);
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode >= 400) {
        throw Exception('HTTP ${response.statusCode}: $responseBody');
      }

      return http.Response(responseBody, response.statusCode);
    } finally {
      client.close();
    }
  }
}
