import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Kilo Code provider adapter.
///
/// API Documentation: https://kilo.ai
class KiloCodeProvider implements LlmProvider {
  KiloCodeProvider({
    required this.apiKey,
    this.model = 'kilocode-70b',
    this.baseUrl = 'https://api.kilo.ai/v1',
    this.httpClient,
    this.requestTimeout = const Duration(seconds: 120),
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client? httpClient;
  final Duration requestTimeout;

  @override
  String get id => 'kilocode';

  @override
  Capabilities get capabilities => const Capabilities(
    toolCalling: true,
    streaming: true,
    maxContext: 131072,
  );

  @override
  Future<List<double>> embed(String text) async => const [];

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final client = httpClient ?? http.Client();
    try {
      final messages = <Map<String, dynamic>>[];
      for (final m in req.messages) {
        final message = <String, dynamic>{
          'role': _mapRole(m.role),
          'content': m.content,
        };
        if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
          message['tool_calls'] = [
            for (final tc in m.toolCalls!)
              {
                'id': tc.id,
                'type': 'function',
                'function': {
                  'name': tc.name,
                  'arguments': jsonEncode(tc.args),
                },
              }
          ];
        }
        messages.add(message);
      }

      final body = <String, dynamic>{
        'model': req.model ?? model,
        'messages': messages,
        'max_tokens': req.maxTokens,
        'temperature': req.temperature ?? 0.7,
        'stream': true,
      };

      body.removeWhere((key, value) => value == null);

      final uri = Uri.parse('$baseUrl/chat/completions');
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
          'Kilo Code HTTP ${res.statusCode}: ${res.body}',
          code: '${res.statusCode}',
        );
        return;
      }

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
                if (delta.containsKey('content')) {
                  yield LlmTextDelta(delta['content'] as String? ?? '');
                }
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
                              : (function['arguments'] as Map<String, dynamic>? ?? {}),
                        ),
                      );
                    }
                  }
                }
              }
            }
          } catch (e) {
            yield LlmError('Kilo Code parse error: $e', code: 'parse_error');
          }
        }
      }

      yield LlmUsage(TokenUsage(prompt: 0, completion: 0, total: 0));
    } catch (e) {
      yield LlmError('Kilo Code error: $e', code: 'network_error');
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
}
