import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Mistral AI provider adapter.
/// Supports Mistral's API-compatible endpoints (Mistral, Mistral Small, etc.)
///
/// API Documentation: https://docs.mistral.ai/api/
class MistralProvider implements LlmProvider {
  MistralProvider({
    required this.apiKey,
    this.model = 'mistral-tiny',
    this.baseUrl = 'https://api.mistral.ai',
    this.httpClient,
    this.requestTimeout = const Duration(seconds: 120),
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client? httpClient;
  final Duration requestTimeout;

  @override
  String get id => 'mistral';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: true, streaming: true, maxContext: 32768);

  @override
  Future<List<double>> embed(String text) async => const [];

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final client = httpClient ?? http.Client();
    try {
      // Convert AgentCore messages to Mistral format
      final messages = <Map<String, dynamic>>[];
      for (final m in req.messages) {
        final message = <String, dynamic>{
          'role': _mapRole(m.role),
          'content': m.content,
        };
        // Add tool calls if present
        if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
          message['tool_calls'] = [
            for (final tc in m.toolCalls!)
              {
                'id': tc.id,
                'type': 'function',
                'function': {'name': tc.name, 'arguments': jsonEncode(tc.args)},
              },
          ];
        }
        messages.add(message);
      }

      // Build request body
      final body = {
        'model': req.model ?? model,
        'messages': messages,
        'max_tokens': req.maxTokens,
        'temperature': req.temperature ?? 0.7,
        'stream': true,
        'stream_options': {'include_usage': true},
      };

      // Remove null values
      body.removeWhere((key, value) => value == null);

      final uri = Uri.parse('$baseUrl/v1/chat/completions');
      final res = await client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);

      if (res.statusCode >= 400) {
        yield LlmError(
          'Mistral HTTP ${res.statusCode}: ${res.body}',
          code: '${res.statusCode}',
        );
        return;
      }

      // Parse streaming response
      final lines = res.body.split('\n');
      var promptTokens = 0;
      var completionTokens = 0;
      var totalTokens = 0;
      var hasUsage = false;
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.startsWith('data: ')) {
          final dataStr = line.substring(6).trim();
          if (dataStr == '[DONE]') break;
          try {
            final json = jsonDecode(dataStr) as Map<String, dynamic>;
            final usage = json['usage'];
            if (usage is Map<String, dynamic>) {
              promptTokens =
                  (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
              completionTokens =
                  (usage['completion_tokens'] as num?)?.toInt() ??
                  completionTokens;
              totalTokens =
                  (usage['total_tokens'] as num?)?.toInt() ??
                  promptTokens + completionTokens;
              hasUsage = true;
            }
            final choices = json['choices'] as List<dynamic>? ?? [];
            for (final choice in choices) {
              final choiceMap = choice as Map<String, dynamic>;
              final delta = choiceMap['delta'] as Map<String, dynamic>?;
              if (delta != null) {
                // Handle text delta
                if (delta.containsKey('content')) {
                  yield LlmTextDelta(delta['content'] as String? ?? '');
                }
                // Handle tool calls
                if (delta.containsKey('tool_calls')) {
                  final toolCalls = delta['tool_calls'] as List<dynamic>? ?? [];
                  for (final tc in toolCalls) {
                    final tcMap = tc as Map<String, dynamic>;
                    final function = tcMap['function'] as Map<String, dynamic>?;
                    if (function != null) {
                      yield LlmToolCall(
                        ToolCall(
                          id: tcMap['id'] as String? ?? '',
                          name: function['name'] as String? ?? '',
                          args: function['arguments'] is String
                              ? jsonDecode(function['arguments'] as String)
                              : (function['arguments']
                                        as Map<String, dynamic>? ??
                                    {}),
                        ),
                      );
                    }
                  }
                }
              }
            }
          } catch (e) {
            yield LlmError('Mistral parse error: $e', code: 'parse_error');
          }
        }
      }

      if (hasUsage) {
        yield LlmUsage(
          TokenUsage(
            prompt: promptTokens,
            completion: completionTokens,
            total: totalTokens == 0
                ? promptTokens + completionTokens
                : totalTokens,
          ),
        );
      }
    } catch (e) {
      yield LlmError('Mistral error: $e', code: 'network_error');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  String _mapRole(String role) {
    switch (role) {
      case 'user':
        return 'user';
      case 'assistant':
        return 'assistant';
      case 'system':
        return 'system';
      case 'tool':
        return 'tool';
      default:
        return 'user';
    }
  }

  /// List available models from the API
  Future<List<String>> listModels() async {
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .get(
            Uri.parse('$baseUrl/v1/models'),
            headers: {'Authorization': 'Bearer $apiKey'},
          )
          .timeout(requestTimeout);

      if (res.statusCode >= 400) {
        throw Exception('Mistral models API error: ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      return data
          .map((m) => (m as Map<String, dynamic>)['id'] as String)
          .toList();
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
