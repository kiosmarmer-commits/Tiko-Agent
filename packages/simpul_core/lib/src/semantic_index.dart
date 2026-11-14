import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'embedding.dart';
import 'vault_crypto.dart';

/// One chunk offered to a semantic index.
class ChunkInput {
  const ChunkInput({
    required this.notePath,
    required this.ord,
    required this.headingPath,
    required this.text,
    required this.hash,
  });

  final String notePath;
  final int ord;
  final String headingPath;
  final String text;

  /// Content hash of the chunk text; unchanged chunks are never re-embedded
  /// (AI-12).
  final String hash;
}

class SemanticHit {
  const SemanticHit({
    required this.notePath,
    required this.ord,
    required this.headingPath,
    required this.score,
  });

  final String notePath;
  final int ord;
  final String headingPath;
  final double score;
}

/// Vector store over chunk embeddings (AI-11..14). Implementations must
/// reject vectors from a different [modelVersion] instead of mixing them
/// (AI-13).
abstract class SemanticIndex {
  String get modelVersion;

  Future<void> replaceAll(List<ChunkInput> chunks);
  Future<void> upsert(List<ChunkInput> chunks);
  Future<void> removeNotes(List<String> paths);

  /// Brute-force cosine search (see ADR-06); [allowedPaths] is the prefilter
  /// (AI-30) so only the filtered subset is scanned.
  Future<List<SemanticHit>> search(
    Float32List query, {
    int limit = 20,
    Set<String>? allowedPaths,
  });

  Future<void> close();
}

/// In-memory index of int8-quantized vectors with optional JSON persistence.
/// Brute-force scan over quantized vectors; ADR-06 records why ANN is not
/// needed at P1 scale.
class InMemorySemanticIndex implements SemanticIndex {
  InMemorySemanticIndex(this.embedder, {this.filePath, this.crypto});

  /// Returns the `model_version` stored in the vector file at [path], or null
  /// when the file is absent or unreadable. Callers use this to fail closed
  /// before opening an index with a mismatched embedder (AI-13).
  static String? storedModelVersion(String path, {VaultCrypto? crypto}) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final raw = VaultFiles.readBytes(path, crypto: crypto);
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      return decoded['model_version']?.toString();
    } on VaultCryptoException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  final EmbeddingProvider embedder;
  final String? filePath;
  final VaultCrypto? crypto;

  final _entries = <_Entry>[];
  bool _loaded = false;

  @override
  String get modelVersion => embedder.modelVersion;

  @override
  Future<void> replaceAll(List<ChunkInput> chunks) async {
    _entries.clear();
    await _embedAndAdd(chunks);
    await _flush();
  }

  @override
  Future<void> upsert(List<ChunkInput> chunks) async {
    _ensureLoaded();
    final indexByKey = {
      for (var i = 0; i < _entries.length; i++) (_entries[i].path, _entries[i].ord): i,
    };
    for (final chunk in chunks) {
      final key = (chunk.notePath, chunk.ord);
      final existing = indexByKey[key];
      if (existing != null && _entries[existing].hash == chunk.hash) continue;
      final vec = QuantizedVector.encode(embedder.embed(chunk.text), modelVersion);
      final entry = _Entry(
        path: chunk.notePath,
        ord: chunk.ord,
        headingPath: chunk.headingPath,
        hash: chunk.hash,
        vec: vec,
      );
      if (existing != null) {
        _entries[existing] = entry;
      } else {
        indexByKey[key] = _entries.length;
        _entries.add(entry);
      }
    }
    await _flush();
  }

  @override
  Future<void> removeNotes(List<String> paths) async {
    _ensureLoaded();
    final removed = paths.toSet();
    _entries.removeWhere((e) => removed.contains(e.path));
    await _flush();
  }

  @override
  Future<List<SemanticHit>> search(
    Float32List query, {
    int limit = 20,
    Set<String>? allowedPaths,
  }) async {
    _ensureLoaded();
    final queryVec = QuantizedVector.encode(query, modelVersion);
    final scored = <(double, _Entry)>[];
    for (final entry in _entries) {
      if (allowedPaths != null && !allowedPaths.contains(entry.path)) continue;
      scored.add((entry.vec.cosine(queryVec), entry));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (score, entry) in scored.take(limit))
        SemanticHit(
          notePath: entry.path,
          ord: entry.ord,
          headingPath: entry.headingPath,
          score: score,
        ),
    ];
  }

  Future<void> _embedAndAdd(List<ChunkInput> chunks) async {
    for (final chunk in chunks) {
      _entries.add(_Entry(
        path: chunk.notePath,
        ord: chunk.ord,
        headingPath: chunk.headingPath,
        hash: chunk.hash,
        vec: QuantizedVector.encode(embedder.embed(chunk.text), modelVersion),
      ));
    }
  }

  void _ensureLoaded() {
    final path = filePath;
    if (_loaded || path == null) return;
    _loaded = true;
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      final raw = VaultFiles.readBytes(path, crypto: crypto);
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      if (decoded['model_version'] != modelVersion) return;
      for (final raw in (decoded['chunks'] as List? ?? const [])) {
        final map = (raw as Map).cast<String, Object?>();
        _entries.add(_Entry(
          path: map['path']!.toString(),
          ord: (map['ord'] as num).toInt(),
          headingPath: map['heading_path']?.toString() ?? '',
          hash: map['hash']!.toString(),
          vec: QuantizedVector(
            Int8List.fromList(base64Decode(map['vec']!.toString())),
            modelVersion,
          ),
        ));
      }
    } on VaultCryptoException {
      _entries.clear();
      rethrow;
    } catch (_) {
      _entries.clear();
    }
  }

  Future<void> _flush() async {
    final path = filePath;
    if (path == null) return;
    await VaultFiles.writeBytes(
      path,
      utf8.encode(jsonEncode({
        'schema_version': 1,
        'model_version': modelVersion,
        'dim': embedder.dimension,
        'chunks': [
          for (final e in _entries)
            {
              'path': e.path,
              'ord': e.ord,
              'heading_path': e.headingPath,
              'hash': e.hash,
              'vec': base64Encode(Uint8List.view(e.vec.data.buffer)),
            },
        ],
      })),
      crypto: crypto,
    );
  }

  @override
  Future<void> close() async {}
}

class _Entry {
  const _Entry({
    required this.path,
    required this.ord,
    required this.headingPath,
    required this.hash,
    required this.vec,
  });

  final String path;
  final int ord;
  final String headingPath;
  final String hash;
  final QuantizedVector vec;
}
