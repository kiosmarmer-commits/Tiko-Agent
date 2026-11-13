import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'embedding.dart';

/// Embedding runtime backed by a local Ollama endpoint (AI-03 option (a)).
/// The default transport talks to `POST <baseUrl>/api/embed`; tests inject a
/// fake [fetch] so no network is required. Everything fails closed: non-200,
/// timeout, or a dimension mismatch becomes a StateError.
class OllamaEmbedder implements AsyncEmbeddingProvider {
  OllamaEmbedder({
    this.model = 'nomic-embed-text',
    this.baseUrl = 'http://localhost:11434',
    int? dimension,
    this.timeout = const Duration(seconds: 30),
    Future<Object?> Function(Uri url, Map<String, Object?> body)? fetch,
  })  : dimension = dimension ?? 768,
        _fetch = fetch ?? _httpFetch;

  final String model;
  final String baseUrl;
  @override
  final int dimension;
  final Duration timeout;
  final Future<Object?> Function(Uri url, Map<String, Object?> body) _fetch;

  static const _versionPrefix = 'ollama';

  @override
  String get modelVersion => '$_versionPrefix:$model';

  @override
  Future<Float32List> embed(String text) async {
    final vectors = await embedBatch([text]);
    return vectors.single;
  }

  /// Embeds several texts in one request; chunk indexing (AI-12) batches here.
  @override
  Future<List<Float32List>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final url = Uri.parse('$baseUrl/api/embed');
    final raw = await _fetchWithTimeout(url, {'model': model, 'input': texts});
    if (raw is! Map<String, Object?>) {
      throw StateError('respon Ollama tidak valid: ${raw.runtimeType}');
    }
    final embeddings = raw['embeddings'];
    if (embeddings is! List || embeddings.length != texts.length) {
      throw StateError(
        'Ollama mengembalikan ${embeddings is List ? embeddings.length : '?'} '
        'vektor, dibutuhkan ${texts.length}',
      );
    }
    return [
      for (final entry in embeddings) _normalize(entry),
    ];
  }

  Float32List _normalize(Object? entry) {
    if (entry is! List) {
      throw StateError('vektor Ollama bukan array');
    }
    if (entry.length != dimension) {
      throw StateError(
        'dimensi vektor Ollama ${entry.length} != $dimension '
        '(atur parameter dimension sesuai model)',
      );
    }
    final vector = Float32List(dimension);
    var sumSquares = 0.0;
    for (var i = 0; i < dimension; i++) {
      final value = (entry[i] as num).toDouble();
      vector[i] = value;
      sumSquares += value * value;
    }
    final norm = math.sqrt(sumSquares);
    if (norm <= 0) {
      throw StateError('vektor Ollama kosong (norm 0)');
    }
    for (var i = 0; i < dimension; i++) {
      vector[i] /= norm;
    }
    return vector;
  }

  Future<Object?> _fetchWithTimeout(Uri url, Map<String, Object?> body) {
    return _fetch(url, body).timeout(timeout, onTimeout: () {
      throw StateError('Ollama tidak merespon dalam $timeout');
    });
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
