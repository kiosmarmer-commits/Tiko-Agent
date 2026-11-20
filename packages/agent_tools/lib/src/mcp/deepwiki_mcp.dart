import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// DeepWiki MCP server tool for accessing DeepWiki knowledge base.
///
/// DeepWiki is a knowledge graph and search service that provides
/// structured information about entities, relationships, and concepts.
///
/// Configuration:
/// - apiKey: DeepWiki API key (required)
/// - baseUrl: DeepWiki API base URL (default: https://api.deepwiki.com)
/// - timeout: Request timeout (default: 30 seconds)
class DeepWikiMcpTool implements Tool {
  DeepWikiMcpTool({
    required this.apiKey,
    this.baseUrl = 'https://api.deepwiki.com',
    this.timeout = const Duration(seconds: 30),
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'deepwiki_mcp';

  @override
  String get description =>
      'DeepWiki MCP server for accessing knowledge graph and structured information.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'search',
                'get_entity',
                'get_relationships',
                'query',
              ],
              'description': 'The DeepWiki action to perform',
            },
            'query': {
              'type': 'string',
              'description': 'Search query or entity ID',
            },
            'entity_id': {
              'type': 'string',
              'description': 'Entity ID for get_entity and get_relationships actions',
            },
            'limit': {
              'type': 'number',
              'description': 'Maximum number of results to return',
              'default': 10,
            },
            'offset': {
              'type': 'number',
              'description': 'Offset for pagination',
              'default': 0,
            },
            'filters': {
              'type': 'object',
              'description': 'Filters for search results',
              'additionalProperties': true,
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(ToolCall call) async {
    try {
      final action = call.args['action'] as String?;
      
      switch (action) {
        case 'search':
          return await _search(call);
        case 'get_entity':
          return await _getEntity(call);
        case 'get_relationships':
          return await _getRelationships(call);
        case 'query':
          return await _query(call);
        default:
          return ToolResult(
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _search(ToolCall call) async {
    try {
      final query = call.args['query'] as String?;
      final limit = call.args['limit'] as num? ?? 10;
      final offset = call.args['offset'] as num? ?? 0;
      final filters = call.args['filters'] as Map<String, dynamic>?;
      
      if (query == null || query.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'query is required'}),
          isError: true,
        );
      }
      
      final requestBody = <String, dynamic>{
        'query': query,
        'limit': limit,
        'offset': offset,
      };
      
      if (filters != null) {
        requestBody['filters'] = filters;
      }
      
      final response = await _makeRequest(
        'POST',
        '/v1/search',
        requestBody,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'query': query,
          'results': data['results'],
          'total': data['total'],
          'limit': data['limit'],
          'offset': data['offset'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to search: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getEntity(ToolCall call) async {
    try {
      final entityId = call.args['entity_id'] as String? ?? call.args['query'] as String?;
      
      if (entityId == null || entityId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'entity_id or query is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/v1/entities/$entityId',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'entity': data['entity'],
          'id': data['id'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get entity: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getRelationships(ToolCall call) async {
    try {
      final entityId = call.args['entity_id'] as String? ?? call.args['query'] as String?;
      final limit = call.args['limit'] as num? ?? 50;
      
      if (entityId == null || entityId.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'entity_id or query is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/v1/entities/$entityId/relationships?limit=$limit',
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'entity_id': entityId,
          'relationships': data['relationships'],
          'count': data['count'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get relationships: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _query(ToolCall call) async {
    try {
      final query = call.args['query'] as String?;
      final limit = call.args['limit'] as num? ?? 10;
      
      if (query == null || query.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'query is required'}),
          isError: true,
        );
      }
      
      final requestBody = <String, dynamic>{
        'query': query,
        'limit': limit,
      };
      
      final response = await _makeRequest(
        'POST',
        '/v1/query',
        requestBody,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'query': query,
          'results': data['results'],
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to query: ${e.toString()}'}),
        isError: true,
      );
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
      if (method == 'GET') {
        final response = await client.get(uri, headers: headers).timeout(timeout);
        return http.Response(response.body, response.statusCode);
      } else {
        final request = http.Request(method, uri)
          ..headers.addAll(headers)
          ..body = body != null ? jsonEncode(body) : null;
        
        final response = await client.send(request).timeout(timeout);
        final responseBody = await response.stream.bytesToString();
        return http.Response(responseBody, response.statusCode);
      }
    } finally {
      client.close();
    }
  }
}
