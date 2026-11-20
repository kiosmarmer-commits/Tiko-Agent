import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Langfuse tool for observability and tracing.
///
/// Langfuse is an observability platform for AI applications that provides
/// tracing, metrics, and debugging capabilities.
///
/// Configuration:
/// - apiKey: Langfuse API key (required)
/// - baseUrl: Langfuse API base URL (default: https://api.langfuse.com)
/// - timeout: Request timeout (default: 30 seconds)
class LangfuseTool implements Tool {
  LangfuseTool({
    required this.apiKey,
    required this.projectId,
    this.baseUrl = 'https://api.langfuse.com',
    this.timeout = const Duration(seconds: 30),
  });

  final String apiKey;
  final String projectId;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'langfuse';

  @override
  String get description =>
      'Langfuse observability tool for tracing and debugging AI applications.';

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
                'create_trace',
                'end_trace',
                'create_span',
                'end_span',
                'create_event',
                'create_generation',
                'end_generation',
                'log',
              ],
              'description': 'The Langfuse action to perform',
            },
            'trace_id': {
              'type': 'string',
              'description': 'Trace ID for trace-related actions',
            },
            'span_id': {
              'type': 'string',
              'description': 'Span ID for span-related actions',
            },
            'parent_id': {
              'type': 'string',
              'description': 'Parent span ID for create_span',
            },
            'name': {
              'type': 'string',
              'description': 'Name for trace, span, or event',
            },
            'input': {
              'type': 'object',
              'description': 'Input data for trace or span',
              'additionalProperties': true,
            },
            'output': {
              'type': 'object',
              'description': 'Output data for trace or span',
              'additionalProperties': true,
            },
            'metadata': {
              'type': 'object',
              'description': 'Metadata for trace, span, or event',
              'additionalProperties': true,
            },
            'message': {
              'type': 'string',
              'description': 'Log message',
            },
            'level': {
              'type': 'string',
              'enum': ['debug', 'info', 'warning', 'error'],
              'description': 'Log level',
            },
            'model': {
              'type': 'string',
              'description': 'Model name for generation',
            },
            'prompt': {
              'type': 'string',
              'description': 'Prompt for generation',
            },
            'completion': {
              'type': 'string',
              'description': 'Completion text for generation',
            },
            'usage': {
              'type': 'object',
              'description': 'Token usage for generation',
              'properties': {
                'promptTokens': {'type': 'number'},
                'completionTokens': {'type': 'number'},
                'totalTokens': {'type': 'number'},
              },
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String?;
      
      switch (action) {
        case 'create_trace':
          return await _createTrace(args, ctx);
        case 'end_trace':
          return await _endTrace(args, ctx);
        case 'create_span':
          return await _createSpan(args, ctx);
        case 'end_span':
          return await _endSpan(args, ctx);
        case 'create_event':
          return await _createEvent(args, ctx);
        case 'create_generation':
          return await _createGeneration(args, ctx);
        case 'end_generation':
          return await _endGeneration(args, ctx);
        case 'log':
          return await _log(args, ctx);
        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createTrace(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final name = args['name'] as String? ?? 'unnamed_trace';
      final input = args['input'] as Map<String, dynamic>?;
      final metadata = args['metadata'] as Map<String, dynamic>? ?? {};
      
      final requestBody = {
        'name': name,
        'projectId': projectId,
        'input': input,
        'metadata': metadata,
      };

      final response = await _makeRequest(
        'POST',
        '/api/traces',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'created',
          'trace_id': data['id'],
          'name': name,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create trace: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _endTrace(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final traceId = args['trace_id'] as String?;
      final output = args['output'] as Map<String, dynamic>?;
      
      if (traceId == null || traceId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'trace_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'output': output,
      };

      await _makeRequest(
        'PATCH',
        '/api/traces/$traceId/end',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'ended',
          'trace_id': traceId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to end trace: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createSpan(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final traceId = args['trace_id'] as String?;
      final name = args['name'] as String? ?? 'unnamed_span';
      final parentId = args['parent_id'] as String?;
      final input = args['input'] as Map<String, dynamic>?;
      final metadata = args['metadata'] as Map<String, dynamic>? ?? {};
      
      if (traceId == null || traceId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'trace_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'traceId': traceId,
        'name': name,
        'parentId': parentId,
        'input': input,
        'metadata': metadata,
      };

      final response = await _makeRequest(
        'POST',
        '/api/spans',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'created',
          'span_id': data['id'],
          'trace_id': traceId,
          'name': name,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create span: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _endSpan(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final spanId = args['span_id'] as String?;
      final output = args['output'] as Map<String, dynamic>?;
      
      if (spanId == null || spanId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'span_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'output': output,
      };

      await _makeRequest(
        'PATCH',
        '/api/spans/$spanId/end',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'ended',
          'span_id': spanId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to end span: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createEvent(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final traceId = args['trace_id'] as String?;
      final spanId = args['span_id'] as String?;
      final name = args['name'] as String? ?? 'unnamed_event';
      final input = args['input'] as Map<String, dynamic>?;
      final metadata = args['metadata'] as Map<String, dynamic>? ?? {};
      
      if (traceId == null || traceId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'trace_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'traceId': traceId,
        'spanId': spanId,
        'name': name,
        'input': input,
        'metadata': metadata,
      };

      final response = await _makeRequest(
        'POST',
        '/api/events',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'created',
          'event_id': data['id'],
          'trace_id': traceId,
          'name': name,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create event: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createGeneration(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final traceId = args['trace_id'] as String?;
      final spanId = args['span_id'] as String?;
      final model = args['model'] as String?;
      final prompt = args['prompt'] as String?;
      final metadata = args['metadata'] as Map<String, dynamic>? ?? {};
      
      if (traceId == null || traceId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'trace_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'traceId': traceId,
        'spanId': spanId,
        'model': model,
        'prompt': prompt,
        'metadata': metadata,
      };

      final response = await _makeRequest(
        'POST',
        '/api/generations',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'created',
          'generation_id': data['id'],
          'trace_id': traceId,
          'model': model,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create generation: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _endGeneration(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final generationId = args['generation_id'] as String?;
      final completion = args['completion'] as String?;
      final usage = args['usage'] as Map<String, dynamic>?;
      
      if (generationId == null || generationId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'generation_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'completion': completion,
        'usage': usage,
      };

      await _makeRequest(
        'PATCH',
        '/api/generations/$generationId/end',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'ended',
          'generation_id': generationId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to end generation: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _log(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final traceId = args['trace_id'] as String?;
      final spanId = args['span_id'] as String?;
      final message = args['message'] as String?;
      final level = args['level'] as String? ?? 'info';
      final metadata = args['metadata'] as Map<String, dynamic>? ?? {};
      
      if (traceId == null || traceId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'trace_id is required'}),
          isError: true,
        );
      }
      if (message == null || message.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'message is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'traceId': traceId,
        'spanId': spanId,
        'message': message,
        'level': level,
        'metadata': metadata,
      };

      final response = await _makeRequest(
        'POST',
        '/api/logs',
        requestBody,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'logged',
          'log_id': data['id'],
          'trace_id': traceId,
          'message': message,
          'level': level,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to log: ${e.toString()}'}),
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
