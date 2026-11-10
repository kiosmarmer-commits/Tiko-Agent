import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Minimal Gemini generateContent adapter (TASK-02-03 smoke).
class GeminiProvider implements LlmProvider {
  GeminiProvider({
    required this.apiKey,
    this.model = 'gemini-2.0-flash',
    this.httpClient,
  });

  final String apiKey;
  final String model;
  final http.Client? httpClient;

  @override
  String get id => 'gemini';

  @override
  Capabilities get capabilities => const Capabilities(
    toolCalling: true,
    streaming: false,
    maxContext: 1000000,
  );

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final client = httpClient ?? http.Client();
    try {
      final contents = <Map<String, dynamic>>[];
      for (final m in req.messages) {
        if (m.role == 'system') {
          contents.add({
            'role': 'user',
            'parts': [
              {'text': '[system] ${m.content}'},
            ],
          });
          continue;
        }
        contents.add({
          'role': m.role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': m.content},
          ],
        });
      }

      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
      );
      final res = await client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'contents': contents}),
      );
      if (res.statusCode >= 400) {
        yield LlmError(
          'Gemini HTTP ${res.statusCode}: ${res.body}',
          code: '${res.statusCode}',
        );
        return;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final candidates = json['candidates'] as List<dynamic>? ?? [];
      if (candidates.isNotEmpty) {
        final content =
            (candidates.first as Map)['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List<dynamic>? ?? [];
        for (final p in parts) {
          final text = (p as Map)['text'] as String?;
          if (text != null) yield LlmTextDelta(text);
        }
      }
      yield const LlmDone();
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}
