import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// MiniMax AI provider adapter.
/// Supports MiniMax's API-compatible endpoints
///
/// API Documentation: https://api.minimax.chat/docs
class MiniMaxProvider implements LlmProvider {
  MiniMaxProvider({
    required this.apiKey,
    this.model = 'abab6-chat',
    this.baseUrl = 'https://api.minimax.chat',
    this.httpClient,
    this.requestTimeout = const Duration(seconds: 120),
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client? httpClient;
  final Duration requestTimeout;

  @override
  String get id => 'minimax';

  @override
  Capabilities get capabilities => const Capabilities(
    toolCalling: true,
    streaming: true,
    maxContext: 32768,
  );

  @override
  Future<List<double>> embed(String text) async => const [];

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final client = httpClient ?? http.Client();
    try {
      // Convert AgentCore messages to MiniMax format
      final messages = <Map<String, dynamic>>[];
      for (final m in req.messages) {
        final message = <String, dynamic>{
          'sender_type': _mapSenderType(m.role),
          'sender_name': _getSenderName(m.role),
          'text': m.content,
        };
        // Add tool calls if present
        if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
          message['function_calls'] = [
            for (final tc in m.toolCalls!)
              {
                'id': tc.id,
                'name': tc.name,
                'arguments': jsonEncode(tc.args),
              }
          ];
        }
        messages.add(message);
      }

      // Build request body
      final body = {
        'model': req.model ?? model,
        'stream': true,
        'messages': messages,
        'temperature': req.temperature ?? 0.7,
        'max_tokens': req.maxTokens,
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
          'MiniMax HTTP ${res.statusCode}: ${res.body}',
          code: '${res.statusCode}',
        );
        return;
      }

      // Parse streaming response
      final lines = res.body.split('\n');
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.startsWith('data: ')) {
          final dataStr = line.substring(6).trim();
          if (dataStr == '[DONE]') break;
          try {
            final json = jsonDecode(dataStr) as Map<String, dynamic>;
            final choices = json['choices'] as List<dynamic>? ?? [];
            for (final choice in choices) {
              final choiceMap = choice as Map<String, dynamic>;
              final delta = choiceMap['delta'] as Map<String, dynamic>?;
              if (delta != null) {
                // Handle text delta
                if (delta.containsKey('text')) {
                  yield LlmTextDelta(delta['text'] as String? ?? '');
                }
                // Handle tool calls
                if (delta.containsKey('function_calls')) {
                  final toolCalls = delta['function_calls'] as List<dynamic>? ?? [];
                  for (final tc in toolCalls) {
                    final tcMap = tc as Map<String, dynamic>;
                    yield LlmToolCall(
                      ToolCall(
                        id: tcMap['id'] as String? ?? '',
                        name: tcMap['name'] as String? ?? '',
                        args: tcMap['arguments'] is String
                            ? jsonDecode(tcMap['arguments'] as String)
                            : (tcMap['arguments'] as Map<String, dynamic>? ?? {}),
                      ),
                    );
                  }
                }
              }
            }
          } catch (e) {
            yield LlmError('MiniMax parse error: $e', code: 'parse_error');
          }
        }
      }

      // Note: Usage is typically sent in the final chunk
      yield LlmUsage(TokenUsage(prompt: 0, completion: 0, total: 0));
    } catch (e) {
      yield LlmError('MiniMax error: $e', code: 'network_error');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  String _mapSenderType(String role) {
    switch (role) {
      case 'system':
      case 'assistant':
        return 'BOT';
      case 'user':
        return 'USER';
      case 'tool':
        return 'FUNCTION';
      default:
        return 'USER';
    }
  }

  String _getSenderName(String role) {
    switch (role) {
      case 'system':
        return 'System';
      case 'assistant':
        return 'Assistant';
      case 'user':
        return 'User';
      case 'tool':
        return 'Function';
      default:
        return role;
    }
  }

  /// List available models from the API
  Future<List<String>> listModels() async {
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .get(
            Uri.parse('$baseUrl/v1/models'),
            headers: {
              'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(requestTimeout);

      if (res.statusCode >= 400) {
        throw Exception('MiniMax models API error: ${res.statusCode}');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      return data.map((m) => (m as Map<String, dynamic>)['id'] as String).toList();
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
