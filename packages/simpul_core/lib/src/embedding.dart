import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Produces embedding vectors for text (AI-11). Implementations must be
/// deterministic and carry a [modelVersion] so stored vectors from a different
/// model are never mixed (AI-13).
abstract class EmbeddingProvider {
  String get modelVersion;
  int get dimension;

  /// Returns an L2-normalized vector for [text].
  Float32List embed(String text);
}

/// Async variant of [EmbeddingProvider] for embedders backed by a local or
/// remote server (AI-03). Stored vectors still carry [modelVersion] so
/// vectors from different models are never mixed (AI-13).
abstract class AsyncEmbeddingProvider {
  String get modelVersion;
  int get dimension;

  /// Returns an L2-normalized vector for [text].
  Future<Float32List> embed(String text);

  /// Embeds several texts, ideally in one server round-trip (AI-12).
  Future<List<Float32List>> embedBatch(List<String> texts);
}

/// Deterministic local embedder via feature hashing over word unigrams,
/// bigrams, and character trigrams. Language-agnostic (Indonesia and English
/// behave identically since no vocabulary is needed) and requires no model
/// download (AI-02).
///
/// This is the P1 baseline: it captures lexical overlap, not deep semantics.
/// A real multilingual model (ONNX Runtime or a local embedding server)
/// plugs in through [EmbeddingProvider] without touching call sites; the
/// ADR-06 evaluation on AI-E01 decides when that switch is warranted.
class HashingEmbedder implements EmbeddingProvider {
  HashingEmbedder({this.dim = 256});

  static const _version = 'hashing-v1';

  final int dim;

  @override
  String get modelVersion => _version;

  @override
  int get dimension => dim;

  @override
  Float32List embed(String text) {
    final weights = Float32List(dim);
    final tokens = _tokenize(text);
    if (tokens.isEmpty) return weights;

    for (final token in tokens) {
      _add(weights, token, 1.0);
    }
    for (var i = 0; i + 1 < tokens.length; i++) {
      _add(weights, '${tokens[i]} ${tokens[i + 1]}', 0.5);
    }
    for (final token in tokens) {
      if (token.length < 4) continue;
      for (var i = 0; i + 3 <= token.length; i++) {
        _add(weights, token.substring(i, i + 3), 0.25);
      }
    }

    var norm = 0.0;
    for (var i = 0; i < dim; i++) {
      norm += weights[i] * weights[i];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < dim; i++) {
        weights[i] /= norm;
      }
    }
    return weights;
  }

  void _add(Float32List weights, String feature, double weight) {
    final h = _fnv1a(feature);
    final idx = h % dim;
    final sign = (h >>> 31).isOdd ? -1.0 : 1.0;
    weights[idx] += sign * weight;
  }

  static List<String> _tokenize(String text) {
    final matches = RegExp(r'\p{L}[\p{L}\p{N}_]*', unicode: true).allMatches(text);
    return [
      for (final m in matches)
        if (m.group(0)!.length >= 2) m.group(0)!.toLowerCase(),
    ];
  }

  static int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final code in utf8.encode(input)) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

/// Serves pre-computed vectors by exact text (AI-03 integration bridge).
/// Async embedders (e.g. [OllamaEmbedder]) batch-embed texts first, then sync
/// call sites ([InMemorySemanticIndex], [HybridSearcher]) consume the results
/// through this adapter. Fail-closed: an unknown text is a StateError, never
/// a silent zero vector.
class ReplayEmbedder implements EmbeddingProvider {
  ReplayEmbedder({
    required this.modelVersion,
    required this.dimension,
    Map<String, Float32List> vectors = const {},
  }) : _vectors = Map.of(vectors);

  @override
  final String modelVersion;

  final Map<String, Float32List> _vectors;

  @override
  final int dimension;

  @override
  Float32List embed(String text) {
    final vector = _vectors[text];
    if (vector == null) {
      throw StateError('vektor untuk teks tidak tersedia (ReplayEmbedder)');
    }
    return vector;
  }

  void put(String text, Float32List vector) => _vectors[text] = vector;
}

/// int8-quantized vector (AI-14). Input must be L2-normalized so values fit
/// in [-1, 1] and the scale factor is constant at 1/127.
class QuantizedVector {
  const QuantizedVector(this.data, this.modelVersion);

  final Int8List data;
  final String modelVersion;

  static QuantizedVector encode(Float32List vector, String modelVersion) {
    final q = Int8List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      q[i] = (vector[i] * 127).round().clamp(-127, 127);
    }
    return QuantizedVector(q, modelVersion);
  }

  Float32List decode() {
    final out = Float32List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] / 127;
    }
    return out;
  }

  /// Cosine similarity computed directly on int8 values (norms cancel the
  /// shared 1/127 scale).
  double cosine(QuantizedVector other) {
    final n = math.min(data.length, other.data.length);
    var dot = 0;
    var na = 0;
    var nb = 0;
    for (var i = 0; i < n; i++) {
      dot += data[i] * other.data[i];
      na += data[i] * data[i];
      nb += other.data[i] * other.data[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}
