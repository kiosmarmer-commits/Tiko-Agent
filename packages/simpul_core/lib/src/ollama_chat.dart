import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Chat completion runtime backed by a local Ollama endpoint (AI-03 option
/// (a)) for "tanya vault" RAG (AI-21) and note suggestions (AI-24). Tests
/// inject a fake [fetch] so no network is required. Everything fails closed:
/// non-200, timeout, or an unexpected response shape becomes a StateError.
class OllamaChat {
  OllamaChat({
    this.model = 'llama3.2',
    this.baseUrl = 'http://localhost:11434',
    this.timeout = const Duration(seconds: 120),
    Future<Object?> Function(Uri url, Map<String, Object?> body)? fetch,
  }) : _fetch = fetch ?? _httpFetch;

  final String model;
  final String baseUrl;
  final Duration timeout;
  final Future<Object?> Function(Uri url, Map<String, Object?> body) _fetch;

  Future<String> complete(String prompt, {String? system}) async {
    final url = Uri.parse('$baseUrl/api/chat');
    final raw = await _fetch(url, {
      'model': model,
      'messages': [
        if (system != null) {'role': 'system', 'content': system},
        {'role': 'user', 'content': prompt},
      ],
      'stream': false,
    }).timeout(timeout, onTimeout: () {
      throw StateError('Ollama tidak merespon dalam $timeout');
    });
    if (raw is! Map<String, Object?>) {
      throw StateError('respon Ollama tidak valid: ${raw.runtimeType}');
    }
    final message = raw['message'];
    if (message is! Map) {
      throw StateError('respon Ollama tanpa message');
    }
    final content = message['content'];
    if (content is! String || content.isEmpty) {
      throw StateError('respon Ollama tanpa konten');
    }
    return content;
  }

  static Future<Object?> _httpFetch(Uri url, Map<String, Object?> body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('Ollama HTTP ${response.statusCode}');
      }
      final text = await response.transform(utf8.decoder).join();
      return jsonDecode(text) as Object?;
    } finally {
      client.close();
    }
  }
}
