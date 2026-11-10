import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'prompt_cache.dart';

/// Minimal Anthropic Messages API adapter (TASK-02-03 smoke).
class AnthropicProvider implements LlmProvider {
  AnthropicProvider({
    required this.apiKey,
    this.model = 'claude-sonnet-4-20250514',
    this.baseUrl = 'https://api.anthropic.com',
    this.httpClient,
    this.promptCache,
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final http.Client? httpClient;

  /// When set, stable system prefixes get Anthropic `cache_control`
  /// breakpoints so Claude reuses the cross-session prefix cache.
  final PromptCacheManager? promptCache;

  @override
  String get id => 'anthropic';

  @override
  Capabilities get capabilities => const Capabilities(
    toolCalling: true,
    streaming: true,
    maxContext: 200000,
  );

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final client = httpClient ?? http.Client();
    try {
      final messages = <Map<String, dynamic>>[];
      String? system;
      for (final m in req.messages) {
        if (m.role == 'system') {
          system = (system == null) ? m.content : '$system\n${m.content}';
          continue;
        }
        messages.add({
          'role': m.role == 'assistant' ? 'assistant' : 'user',
          'content': m.content,
        });
      }

      final cache = promptCache;
      if (cache != null && system != null) {
        cache.observe(model: req.model ?? model, systemPrompt: system);
      }
      final body = {
        'model': req.model ?? model,
        'max_tokens': req.maxTokens ?? 4096,
        'messages': messages,
        if (system != null)
          'system': cache != null
              ? const AnthropicCacheBreaker().buildBlocks(system)
              : system,
        'stream': false,
      };

      final res = await client.post(
        Uri.parse('$baseUrl/v1/messages'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: jsonEncode(body),
      );
      if (res.statusCode >= 400) {
        yield LlmError(
          'Anthropic HTTP ${res.statusCode}: ${res.body}',
          code: '${res.statusCode}',
        );
        return;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final content = json['content'] as List<dynamic>? ?? [];
      for (final c in content) {
        final block = c as Map<String, dynamic>;
        if (block['type'] == 'text') {
          yield LlmTextDelta(block['text'] as String? ?? '');
        }
      }
      final usage = json['usage'] as Map<String, dynamic>?;
      if (usage != null) {
        yield LlmUsage(
          TokenUsage(
            prompt: (usage['input_tokens'] as num?)?.toInt() ?? 0,
            completion: (usage['output_tokens'] as num?)?.toInt() ?? 0,
            total:
                ((usage['input_tokens'] as num?)?.toInt() ?? 0) +
                ((usage['output_tokens'] as num?)?.toInt() ?? 0),
          ),
        );
      }
      yield const LlmDone();
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}
