import 'dart:convert';
import 'dart:io';

/// RAG-02 — persistensi cache embedding chunk (`RagPipeline._chunkVectors`)
/// ke disk sebagai file JSON berversi. Setelah restart, semantic rerank
/// tidak lagi kehilangan cached vector: pipeline memuat cache ini dan
/// fallback re-embed on-demand hanya untuk id yang belum tercakup.
class ChunkVectorCache {
  ChunkVectorCache(this.path);

  final String path;

  /// Dimensi vector yang dikenal cache; vector dengan dimensi berbeda
  /// (embedder berganti model) dianggap stale dan dilompati saat load.
  int? _dimension;
  final Map<String, List<double>> _vectors = {};

  int get count => _vectors.length;

  List<double>? get(String id) => _vectors[id];

  void upsert(String id, List<double> vector) {
    if (vector.isEmpty) return;
    final dim = _dimension ?? vector.length;
    if (vector.length != dim) return;
    _dimension = dim;
    _vectors[id] = vector;
  }

  void remove(String id) {
    _vectors.remove(id);
  }

  void retainWhere(bool Function(String id) predicate) {
    _vectors.removeWhere((id, _) => !predicate(id));
  }

  Future<void> load() async {
    final f = File(path);
    if (!await f.exists()) return;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final version = json['version'];
      if (version is! int || version < 1) return;
      final raw = json['vectors'] as Map<String, dynamic>? ?? {};
      raw.forEach((id, value) {
        if (value is! List || value.isEmpty) return;
        final vec = <double>[
          for (final v in value)
            if (v is num) v.toDouble(),
        ];
        if (vec.isEmpty) return;
        final dim = _dimension ?? vec.length;
        if (vec.length != dim) return;
        _dimension = dim;
        _vectors[id] = vec;
      });
    } catch (e) {
      stderr.writeln('chunk_vector_cache: load gagal, mulai kosong: $e');
    }
  }

  Future<void> save() async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(
      jsonEncode({'version': 1, 'dimension': _dimension, 'vectors': _vectors}),
    );
  }
}
