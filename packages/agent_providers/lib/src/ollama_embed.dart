import 'dart:convert';

import 'package:http/http.dart' as http;

/// Ollama embeddings helper for memory vectors.
class OllamaEmbedder {
  OllamaEmbedder({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'nomic-embed-text',
    http.Client? client,
  }) : _client = client;

  final String baseUrl;
  final String model;
  final http.Client? _client;

  Future<List<double>> embed(String text) async {
    final client = _client ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('$baseUrl/api/embeddings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': model, 'prompt': text}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final emb = json['embedding'] as List<dynamic>?;
      if (emb == null) return const [];
      return emb.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return const [];
    } finally {
      if (_client == null) client.close();
    }
  }
}
