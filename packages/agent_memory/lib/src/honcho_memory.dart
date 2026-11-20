import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Honcho memory provider for long-term memory storage.
///
/// Honcho is a long-term memory plugin that provides persistent
/// conversation history and knowledge storage for AI agents.
///
/// Configuration:
/// - apiKey: Honcho API key (required)
/// - baseUrl: Honcho API base URL (default: https://api.honcho.ai)
/// - timeout: Request timeout (default: 30 seconds)
class HonchoMemoryProvider implements MemoryProvider {
  HonchoMemoryProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.honcho.ai',
    this.timeout = const Duration(seconds: 30),
    this.sessionId,
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final String? sessionId;

  @override
  String get name => 'honcho';

  @override
  Future<void> upsert(MemoryItem item) async {
    try {
      final requestBody = {
        'session_id': sessionId ?? item.sessionId,
        'key': item.key,
        'value': item.value,
        'metadata': item.metadata,
        'timestamp': item.timestamp.toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/memory/upsert',
        requestBody,
      );
    } catch (e) {
      throw MemoryException('Failed to upsert memory: ${e.toString()}');
    }
  }

  @override
  Future<List<MemoryItem>> search(String query, {int limit = 10, Map<String, dynamic>? filters}) async {
    try {
      final requestBody = {
        'session_id': sessionId,
        'query': query,
        'limit': limit,
        'filters': filters,
      };

      final response = await _makeRequest(
        'POST',
        '/v1/memory/search',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>? ?? [];

      return results.map((item) => MemoryItem(
            key: item['key'] as String? ?? '',
            value: item['value'] as String? ?? '',
            metadata: item['metadata'] as Map<String, dynamic>? ?? {},
            timestamp: DateTime.parse(item['timestamp'] as String? ?? DateTime.now().toIso8601String()),
            sessionId: item['session_id'] as String? ?? sessionId,
          )).toList();
    } catch (e) {
      throw MemoryException('Failed to search memory: ${e.toString()}');
    }
  }

  @override
  Future<void> forget(String key) async {
    try {
      final requestBody = {
        'session_id': sessionId,
        'key': key,
      };

      await _makeRequest(
        'POST',
        '/v1/memory/forget',
        requestBody,
      );
    } catch (e) {
      throw MemoryException('Failed to forget memory: ${e.toString()}');
    }
  }

  @override
  Future<void> clear({String? sessionId}) async {
    try {
      final requestBody = {
        'session_id': sessionId ?? this.sessionId,
      };

      await _makeRequest(
        'POST',
        '/v1/memory/clear',
        requestBody,
      );
    } catch (e) {
      throw MemoryException('Failed to clear memory: ${e.toString()}');
    }
  }

  @override
  Future<List<MemoryItem>> getAll({String? sessionId, int limit = 100}) async {
    try {
      final requestBody = {
        'session_id': sessionId ?? this.sessionId,
        'limit': limit,
      };

      final response = await _makeRequest(
        'POST',
        '/v1/memory/get_all',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>? ?? [];

      return results.map((item) => MemoryItem(
            key: item['key'] as String? ?? '',
            value: item['value'] as String? ?? '',
            metadata: item['metadata'] as Map<String, dynamic>? ?? {},
            timestamp: DateTime.parse(item['timestamp'] as String? ?? DateTime.now().toIso8601String()),
            sessionId: item['session_id'] as String? ?? sessionId,
          )).toList();
    } catch (e) {
      throw MemoryException('Failed to get all memory: ${e.toString()}');
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
        ..body = body != null ? jsonEncode(body) : null;

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
