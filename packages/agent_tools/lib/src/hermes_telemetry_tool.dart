import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Hermes Telemetry tool for monitoring and analytics.
///
/// Hermes Telemetry is a monitoring and analytics service specifically
/// designed for Hermes AI agents, providing insights into agent performance,
/// usage patterns, and error tracking.
///
/// Configuration:
/// - apiKey: Hermes Telemetry API key (required)
/// - baseUrl: Hermes Telemetry API base URL (default: https://telemetry.hermes.ai)
/// - timeout: Request timeout (default: 30 seconds)
class HermesTelemetryTool implements Tool {
  HermesTelemetryTool({
    required this.apiKey,
    this.baseUrl = 'https://telemetry.hermes.ai',
    this.timeout = const Duration(seconds: 30),
    this.agentId,
    this.agentVersion,
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final String? agentId;
  final String? agentVersion;


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
                'track_event',
                'track_llm_call',
                'track_tool_call',
                'track_error',
                'track_session_start',
                'track_session_end',
                'set_user',
                'set_metadata',
                'increment_counter',
                'record_duration',
              ],
              'description': 'The Hermes Telemetry action to perform',
            },
            'event_name': {
              'type': 'string',
              'description': 'Name of the event to track',
            },
            'model': {
              'type': 'string',
              'description': 'LLM model name for track_llm_call',
            },
            'prompt_tokens': {
              'type': 'number',
              'description': 'Number of prompt tokens for track_llm_call',
            },
            'completion_tokens': {
              'type': 'number',
              'description': 'Number of completion tokens for track_llm_call',
            },
            'total_tokens': {
              'type': 'number',
              'description': 'Total tokens for track_llm_call',
            },
            'tool_name': {
              'type': 'string',
              'description': 'Tool name for track_tool_call',
            },
            'tool_input': {
              'type': 'object',
              'description': 'Tool input for track_tool_call',
              'additionalProperties': true,
            },
            'tool_output': {
              'type': 'object',
              'description': 'Tool output for track_tool_call',
              'additionalProperties': true,
            },
            'error_type': {
              'type': 'string',
              'description': 'Error type for track_error',
            },
            'error_message': {
              'type': 'string',
              'description': 'Error message for track_error',
            },
            'error_stack': {
              'type': 'string',
              'description': 'Error stack trace for track_error',
            },
            'session_id': {
              'type': 'string',
              'description': 'Session ID for session tracking',
            },
            'user_id': {
              'type': 'string',
              'description': 'User ID for set_user',
            },
            'user_properties': {
              'type': 'object',
              'description': 'User properties for set_user',
              'additionalProperties': true,
            },
            'metadata': {
              'type': 'object',
              'description': 'Metadata for set_metadata',
              'additionalProperties': true,
            },
            'counter_name': {
              'type': 'string',
              'description': 'Counter name for increment_counter',
            },
            'increment_by': {
              'type': 'number',
              'description': 'Amount to increment by',
              'default': 1,
            },
            'duration_name': {
              'type': 'string',
              'description': 'Duration name for record_duration',
            },
            'duration_ms': {
              'type': 'number',
              'description': 'Duration in milliseconds for record_duration',
            },
            'properties': {
              'type': 'object',
              'description': 'Additional properties for any event',
              'additionalProperties': true,
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
        case 'track_event':
          return await _trackEvent(args, ctx);
        case 'track_llm_call':
          return await _trackLlmCall(args, ctx);
        case 'track_tool_call':
          return await _trackToolCall(args, ctx);
        case 'track_error':
          return await _trackError(args, ctx);
        case 'track_session_start':
          return await _trackSessionStart(args, ctx);
        case 'track_session_end':
          return await _trackSessionEnd(args, ctx);
        case 'set_user':
          return await _setUser(args, ctx);
        case 'set_metadata':
          return await _setMetadata(args, ctx);
        case 'increment_counter':
          return await _incrementCounter(args, ctx);
        case 'record_duration':
          return await _recordDuration(args, ctx);
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

  Future<ToolResult> _trackEvent(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final eventName = args['event_name'] as String?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      if (eventName == null || eventName.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'event_name is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': eventName,
        'properties': properties,
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'event': eventName,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track event: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _trackLlmCall(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final model = args['model'] as String?;
      final promptTokens = args['prompt_tokens'] as num?;
      final completionTokens = args['completion_tokens'] as num?;
      final totalTokens = args['total_tokens'] as num?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      if (model == null || model.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'model is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': 'llm_call',
        'properties': {
          'model': model,
          'prompt_tokens': promptTokens,
          'completion_tokens': completionTokens,
          'total_tokens': totalTokens,
          ...properties,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'model': model,
          'tokens': totalTokens,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track LLM call: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _trackToolCall(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final toolName = args['tool_name'] as String?;
      final toolInput = args['tool_input'] as Map<String, dynamic>?;
      final toolOutput = args['tool_output'] as Map<String, dynamic>?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      if (toolName == null || toolName.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'tool_name is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': 'tool_call',
        'properties': {
          'tool_name': toolName,
          'tool_input': toolInput,
          'tool_output': toolOutput,
          ...properties,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'tool': toolName,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track tool call: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _trackError(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final errorType = args['error_type'] as String?;
      final errorMessage = args['error_message'] as String?;
      final errorStack = args['error_stack'] as String?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      if (errorType == null || errorType.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'error_type is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': 'error',
        'properties': {
          'error_type': errorType,
          'error_message': errorMessage,
          'error_stack': errorStack,
          ...properties,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'error_type': errorType,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track error: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _trackSessionStart(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': 'session_start',
        'properties': {
          'session_id': sessionId,
          ...properties,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'session_id': sessionId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track session start: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _trackSessionEnd(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final sessionId = args['session_id'] as String?;
      final properties = args['properties'] as Map<String, dynamic>? ?? {};
      
      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'event': 'session_end',
        'properties': {
          'session_id': sessionId,
          ...properties,
        },
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/events',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'tracked',
          'session_id': sessionId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to track session end: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _setUser(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final userId = args['user_id'] as String?;
      final userProperties = args['user_properties'] as Map<String, dynamic>? ?? {};
      
      if (userId == null || userId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'user_id is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'userId': userId,
        'properties': userProperties,
      };

      await _makeRequest(
        'POST',
        '/v1/users',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'set',
          'user_id': userId,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to set user: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _setMetadata(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final metadata = args['metadata'] as Map<String, dynamic>?;
      
      if (metadata == null || metadata.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'metadata is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'metadata': metadata,
      };

      await _makeRequest(
        'POST',
        '/v1/metadata',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'set',
          'metadata': metadata,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to set metadata: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _incrementCounter(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final counterName = args['counter_name'] as String?;
      final incrementBy = args['increment_by'] as num? ?? 1;
      
      if (counterName == null || counterName.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'counter_name is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'counter': counterName,
        'increment': incrementBy,
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/counters',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'incremented',
          'counter': counterName,
          'value': incrementBy,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to increment counter: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _recordDuration(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final durationName = args['duration_name'] as String?;
      final durationMs = args['duration_ms'] as num?;
      
      if (durationName == null || durationName.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'duration_name is required'}),
          isError: true,
        );
      }
      if (durationMs == null) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'duration_ms is required'}),
          isError: true,
        );
      }

      final requestBody = {
        'agentId': agentId,
        'agentVersion': agentVersion,
        'name': durationName,
        'durationMs': durationMs,
        'timestamp': DateTime.now().toIso8601String(),
      };

      await _makeRequest(
        'POST',
        '/v1/durations',
        requestBody,
      );

      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'recorded',
          'name': durationName,
          'duration_ms': durationMs,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to record duration: ${e.toString()}'}),
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
