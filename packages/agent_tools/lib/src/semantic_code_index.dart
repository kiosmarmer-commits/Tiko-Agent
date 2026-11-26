import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'code_search_tool.dart';
import 'path_safety.dart';

/// S22 — indeks kode semantik: chunk kode jendela baris (gaya `code_search`)
/// + vektor embedding per chunk, persisten di `<dataDir>/index/`
/// `code-semantic.jsonl`, refresh inkremental via hash sha256 per file.
/// Ranking hybrid: BM25-lite (formula `code_search`) dipadukan cosine
/// similarity via Reciprocal Rank Fusion.
///
/// Sumber embedding:
/// - Bila host menyuntikkan [CodeEmbedder] (provider `memory.embed`), vektor
///   semantik penuh dipakai. Kegagalan embed saat build menurunkan seluruh
///   refresh ke fallback hashing agar dim konsisten (fail-closed).
/// - Tanpa embedder, [HashingCodeEmbedder] offline deterministik dipakai.
///   Ini BUKAN model semantik — hanya hashing token+trigram; label jujur
///   disertakan di output.
///
/// Read-only terhadap workspace; satu-satunya tulisan adalah file indeks.
typedef CodeEmbedder = Future<List<double>> Function(String text);

/// Embedder offline deterministik: feature hashing token (normalisasi
/// camelCase/snake_case dari `CodeSearchTool.termsOf`) + trigram karakter
/// ke vektor dim tetap, L2-dinormalisasi. Tanpa I/O dan tanpa model.
class HashingCodeEmbedder {
  const HashingCodeEmbedder({this.dim = 256});

  final int dim;

  String get label =>
      'hashing-$dim (offline deterministik, bukan model semantik)';

  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c & 0xff;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  Future<List<double>> call(String text) async {
    final v = List<double>.filled(dim, 0);
    void bump(String token, double w) {
      if (token.isEmpty || token.length < 2) return;
      v[_fnv1a(token) % dim] += w;
      final lowered = token.toLowerCase();
      if (lowered != token) v[_fnv1a(lowered) % dim] += w * 0.5;
    }

    for (final token in CodeSearchTool.termsOf(text)) {
      bump(token, 1.0);
      if (token.length >= 3) {
        for (var i = 0; i + 3 <= token.length; i++) {
          bump('~${token.substring(i, i + 3)}', 0.3);
        }
      }
    }
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm <= 0) return List<double>.filled(dim, 0);
    norm = math.sqrt(norm);
    for (var i = 0; i < dim; i++) {
      v[i] /= norm;
    }
    return v;
  }
}

class SemanticChunk {
  const SemanticChunk({
    required this.relPath,
    required this.start,
    required this.end,
    required this.terms,
    required this.definition,
    required this.snippet,
    this.vector = const <double>[],
  });

  final String relPath;
  final int start;
  final int end;
  final Set<String> terms;
  final bool definition;
  final List<String> snippet;
  final List<double> vector;

  bool get embedded => vector.isNotEmpty;

  double cosine(List<double> q) {
    if (!embedded || q.length != vector.length) return 0;
    var dot = 0.0;
    for (var i = 0; i < q.length; i++) {
      dot += q[i] * vector[i];
    }
    return dot;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': relPath,
        'start': start,
        'end': end,
        'terms': terms.toList()..sort(),
        'definition': definition,
        'snippet': snippet,
        'vector': vector.map((x) => (x * 1e4).round() / 1e4).toList(),
      };

  static SemanticChunk fromJson(Map<String, dynamic> j) {
    final rawTerms = j['terms'];
    final rawSnippet = j['snippet'];
    final rawVector = j['vector'];
    return SemanticChunk(
      relPath: j['path'] as String? ?? '',
      start: (j['start'] as num?)?.toInt() ?? 0,
      end: (j['end'] as num?)?.toInt() ?? 0,
      terms:
          rawTerms is List ? rawTerms.whereType<String>().toSet() : <String>{},
      definition: j['definition'] == true,
      snippet: rawSnippet is List
          ? rawSnippet.whereType<String>().toList()
          : const <String>[],
      vector: rawVector is List
          ? rawVector.whereType<num>().map((x) => x.toDouble()).toList()
          : const <double>[],
    );
  }
}

class SemanticFileEntry {
  const SemanticFileEntry({
    required this.relPath,
    required this.hash,
    required this.size,
    required this.mtimeMs,
    required this.chunks,
  });

  final String relPath;
  final String hash;
  final int size;
  final int mtimeMs;
  final List<SemanticChunk> chunks;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': 'file',
        'path': relPath,
        'hash': hash,
        'size': size,
        'mtime': mtimeMs,
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };

  static SemanticFileEntry fromJson(Map<String, dynamic> j) {
    final rawChunks = j['chunks'];
    return SemanticFileEntry(
      relPath: j['path'] as String? ?? '',
      hash: j['hash'] as String? ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      mtimeMs: (j['mtime'] as num?)?.toInt() ?? 0,
      chunks: rawChunks is List
          ? rawChunks
              .whereType<Map>()
              .map((c) => SemanticChunk.fromJson(Map<String, dynamic>.from(c)))
              .toList()
          : const <SemanticChunk>[],
    );
  }
}

class SemanticHit {
  const SemanticHit({
    required this.chunk,
    required this.bm25Rank,
    required this.cosineRank,
    required this.score,
    required this.cosineSim,
  });

  final SemanticChunk chunk;
  final int bm25Rank;
  final int cosineRank;
  final double score;
  final double cosineSim;

  bool get hybrid => cosineRank > 0;
}

class SemanticCodeIndexer {
  SemanticCodeIndexer({
    required this.workspaceRoot,
    required this.dataDir,
    CodeEmbedder? embedder,
    this.maxFiles = 1500,
    this.maxChunks = 6000,
    this.chunkLines = 24,
    this.chunkOverlap = 8,
    this.maxFileSize = 256 * 1024,
    this.maxEmbedChars = 4000,
  })  : _providerEmbedder = embedder,
        _hashing = const HashingCodeEmbedder();

  final String workspaceRoot;
  final String dataDir;
  final CodeEmbedder? _providerEmbedder;
  final HashingCodeEmbedder _hashing;
  final int maxFiles;
  final int maxChunks;
  final int chunkLines;
  final int chunkOverlap;
  final int maxFileSize;
  final int maxEmbedChars;

  static const _junkDirs = CodeSearchTool.junkDirs;
  static const _codeExts = CodeSearchTool.codeExts;

  final Map<String, SemanticFileEntry> _entries = {};
  String? _embedderUsed;
  int? _dim;
  DateTime? _builtAt;
  bool _loaded = false;
  Future<void> _busy = Future.value();

  String get indexFilePath => p.join(dataDir, 'index', 'code-semantic.jsonl');

  /// Label sumber embedding indeks terakhir yang dibangun (jujur).
  String get embedderLabel => _embedderUsed ?? '(belum dibangun)';

  bool get built => _entries.isNotEmpty;

  /// Serialisasi operasi pada satu instance (refresh/search menulis status
  /// in-memory bersama — hindari race tanpa lock OS).
  Future<T> _serialize<T>(Future<T> Function() op) {
    final done = _busy.then((_) => op());
    _busy = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  int get chunkCount =>
      _entries.values.fold(0, (acc, e) => acc + e.chunks.length);

  /// Bangun/refresh indeks inkremental. File yang hash-nya tidak berubah
  /// dipakai ulang tanpa re-embed; file baru/berubah di-embed ulang; file
  /// yang hilang dipangkas. Melewati [deadline] atau [maxChunks] disimpan
  /// sebagai status `partial` (jujur), bukan diam-diam diabaikan.
  Future<Map<String, dynamic>> refresh({
    Duration deadline = const Duration(seconds: 45),
  }) =>
      _serialize(() => _refresh(deadline));

  Future<Map<String, dynamic>> _refresh(Duration deadline) async {
    _ensureLoaded();
    final sw = Stopwatch()..start();
    final files = _collectFiles(workspaceRoot);
    CodeEmbedder active = _providerEmbedder ?? _hashing.call;
    var activeLabel =
        _providerEmbedder != null ? 'provider (memory.embed)' : _hashing.label;
    var reused = 0;
    var reembeddedFiles = 0;
    var reembeddedChunks = 0;
    var prunedChunks = 0;
    var partial = false;

    final next = <String, SemanticFileEntry>{};
    var totalChunks = 0;
    for (final filePath in files) {
      final rel = p.relative(filePath, from: workspaceRoot);
      final norm = _normalize(rel);
      _FileStamp stamp;
      try {
        final f = File(filePath);
        final bytes = f.readAsBytesSync();
        stamp = _FileStamp(
          hash: crypto.sha256.convert(bytes).toString(),
          size: bytes.length,
          mtimeMs: f.lastModifiedSync().millisecondsSinceEpoch,
        );
      } on FileSystemException {
        continue;
      }
      final prev = _entries[norm];
      if (prev != null && prev.hash == stamp.hash) {
        next[norm] = prev;
        totalChunks += prev.chunks.length;
        reused++;
        continue;
      }
      if (prev != null) prunedChunks += prev.chunks.length;
      if (sw.elapsed > deadline || totalChunks >= maxChunks) {
        partial = true;
        break;
      }
      var entry =
          await _buildFileEntry(filePath, rel, stamp, active);
      if (entry == null && identical(active, _providerEmbedder)) {
        // Provider embed gagal (timeout/status >= 400/dim 0): seluruh
        // refresh diskor turun ke hashing agar dim konsisten — kosongkan
        // reuse yang membawa vektor provider lama.
        active = _hashing.call;
        activeLabel = '${_hashing.label} (fallback: provider embed gagal)';
        next.clear();
        totalChunks = 0;
        reused = 0;
        partial = true; // file terlewat sebelum switch perlu build ulang
        // Mulai ulang ke palangan awal agar file yang terpaku reuse dengan
        // vektor lama di-embed ulang dua kali? File reuse tidak ditandai,
        // jadi tidak — cukup lanjut; file sebelum switch yang gagal diproses
        // pada refresh berikutnya.
        entry = await _buildFileEntry(filePath, rel, stamp, active);
      }
      if (entry == null) continue;
      if (totalChunks + entry.chunks.length > maxChunks) {
        partial = true;
        break;
      }
      reembeddedFiles++;
      reembeddedChunks += entry.chunks.length;
      totalChunks += entry.chunks.length;
      next[norm] = entry;
    }

    final removed =
        _entries.keys.where((k) => !next.containsKey(k)).toList();
    prunedChunks += removed.fold<int>(
        0, (acc, k) => acc + _entries[k]!.chunks.length);
    _entries
      ..clear()
      ..addAll(next);

    _embedderUsed = activeLabel;
    for (final e in _entries.values) {
      final v = e.chunks.where((c) => c.embedded).map((c) => c.vector);
      if (v.isNotEmpty) {
        _dim = v.first.length;
        break;
      }
    }
    _builtAt = DateTime.now().toUtc();
    _persist();

    return <String, dynamic>{
      'files': _entries.length,
      'chunks': chunkCount,
      'reused_files': reused,
      'reembedded_files': reembeddedFiles,
      'reembedded_chunks': reembeddedChunks,
      'pruned_chunks': prunedChunks,
      'partial': partial,
      'embedder': _embedderUsed,
      'dim': _dim ?? 0,
      'elapsed_ms': sw.elapsedMilliseconds,
      'built_at': _builtAt!.toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> status({bool deep = false}) =>
      _serialize(() => _status(deep));

  Future<Map<String, dynamic>> _status(bool deep) async {
    _ensureLoaded();
    final out = <String, dynamic>{
      'index_file': indexFilePath,
      'exists': _entries.isNotEmpty,
      'files': _entries.length,
      'chunks': chunkCount,
      'embedder': _embedderUsed,
      'dim': _dim ?? 0,
      'built_at': _builtAt?.toIso8601String(),
    };
    if (deep) {
      final sw = Stopwatch()..start();
      var stale = 0;
      final files = _collectFiles(workspaceRoot);
      for (final filePath in files) {
        final rel = p.relative(filePath, from: workspaceRoot);
        final prev = _entries[_normalize(rel)];
        if (prev == null) {
          stale++;
          continue;
        }
        try {
          final bytes = File(filePath).readAsBytesSync();
          if (crypto.sha256.convert(bytes).toString() != prev.hash) {
            stale++;
          }
        } on FileSystemException {
          stale++;
        }
      }
      out['stale_files'] = stale;
      out['deep_elapsed_ms'] = sw.elapsedMilliseconds;
    }
    return out;
  }

  Future<List<SemanticHit>> search(
    String query, {
    String? pathPrefix,
    int limit = 10,
  }) =>
      _serialize(() => _search(query, pathPrefix, limit));

  Future<List<SemanticHit>> _search(
    String query,
    String? pathPrefix,
    int limit,
  ) async {
    _ensureLoaded();
    final q = query.trim();
    if (_entries.isEmpty || q.isEmpty) return const [];
    final queryTerms = CodeSearchTool.termsOf(q);
    if (queryTerms.isEmpty) return const [];
    final candidates = <SemanticChunk>[];
    for (final e in _entries.values) {
      if (!_underPrefix(e.relPath, pathPrefix)) continue;
      candidates.addAll(e.chunks);
    }
    if (candidates.isEmpty) return const [];

    final bm25 = _bm25Rank(candidates, queryTerms);

    // Vektor query: dari embedder aktif; gagal/dim-mismatch -> hashing.
    List<double> qv = const [];
    final indexDim = _dim;
    final active = _providerEmbedder ?? _hashing.call;
    try {
      qv = await active(q);
    } catch (_) {
      qv = const [];
    }
    if (qv.length != (indexDim ?? qv.length)) {
      try {
        qv = await _hashing(q);
      } catch (_) {
        qv = const [];
      }
    }
    final cosRanked = <(SemanticChunk, double)>[];
    if (qv.isNotEmpty && qv.length == (indexDim ?? qv.length)) {
      for (final c in candidates) {
        final sim = c.cosine(qv);
        if (sim > 0) cosRanked.add((c, sim));
      }
      cosRanked.sort((a, b) => b.$2.compareTo(a.$2));
    }

    const rrfK = 60;
    final cosRankByChunk = <SemanticChunk, int>{};
    for (var i = 0; i < cosRanked.length && i < 200; i++) {
      cosRankByChunk[cosRanked[i].$1] = i + 1;
    }
    final fused = <SemanticHit>[];
    final seen = <SemanticChunk>{};
    for (var i = 0; i < bm25.length; i++) {
      final c = bm25[i].$1;
      final br = i + 1;
      final cr = cosRankByChunk[c];
      var s = 1 / (rrfK + br);
      if (cr != null) s += 1 / (rrfK + cr);
      if (c.definition) s *= 1.2;
      seen.add(c);
      fused.add(SemanticHit(
        chunk: c,
        bm25Rank: br,
        cosineRank: cr ?? -1,
        score: s,
        cosineSim: cr != null ? cosRanked[cr - 1].$2 : 0,
      ));
    }
    for (var i = 0; i < cosRanked.length; i++) {
      final c = cosRanked[i].$1;
      if (seen.contains(c)) continue;
      final cr = i + 1;
      fused.add(SemanticHit(
        chunk: c,
        bm25Rank: 999999,
        cosineRank: cr,
        score: 1 / (rrfK + cr),
        cosineSim: cosRanked[i].$2,
      ));
    }
    fused.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byPath = a.chunk.relPath.compareTo(b.chunk.relPath);
      if (byPath != 0) return byPath;
      return a.chunk.start.compareTo(b.chunk.start);
    });
    return fused.take(limit).toList();
  }

  List<(SemanticChunk, double)> _bm25Rank(
    List<SemanticChunk> candidates,
    Set<String> queryTerms,
  ) {
    final df = <String, int>{};
    for (final c in candidates) {
      for (final t in c.terms) {
        df[t] = (df[t] ?? 0) + 1;
      }
    }
    final n = candidates.length;
    double idf(String t) => math.log(1 + n / (1 + (df[t] ?? 0)));
    final scored = <(SemanticChunk, double)>[];
    for (final c in candidates) {
      final tf = <String, int>{};
      for (final t in c.terms) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      var score = 0.0;
      var matched = 0;
      for (final q in queryTerms) {
        final t = tf[q];
        if (t == null) continue;
        matched++;
        score += (1 + math.log(1 + t)) * idf(q);
      }
      if (score <= 0) continue;
      score *= 1 + 0.15 * (matched / queryTerms.length);
      if (c.definition) score *= 1.5;
      scored.add((c, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored;
  }

  bool _underPrefix(String relPath, String? prefixRaw) {
    if (prefixRaw == null || prefixRaw.isEmpty) return true;
    var prefix = prefixRaw;
    while (prefix.startsWith('./')) {
      prefix = prefix.substring(2);
    }
    if (prefix.endsWith('/')) prefix = prefix.substring(0, prefix.length - 1);
    if (prefix.isEmpty || prefix == '.') return true;
    return relPath == prefix || relPath.startsWith('$prefix/');
  }

  String _normalize(String rel) => p.normalize(rel);

  Future<SemanticFileEntry?> _buildFileEntry(
    String filePath,
    String rel,
    _FileStamp stamp,
    CodeEmbedder embed,
  ) async {
    try {
      final lines = File(filePath).readAsLinesSync();
      if (chunkLines <= chunkOverlap) return null;
      final chunks = <SemanticChunk>[];
      var start = 0;
      while (start < lines.length) {
        final end = (start + chunkLines > lines.length)
            ? lines.length
            : start + chunkLines;
        final slice = lines.sublist(start, end);
        final terms = <String>{};
        var definition = false;
        for (final line in slice) {
          terms.addAll(CodeSearchTool.termsOf(line));
          if (!definition &&
              CodeSearchTool.definitionPattern.hasMatch(line)) {
            definition = true;
          }
        }
        final body = slice
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .take(6)
            .toList();
        if (terms.isNotEmpty && chunks.length < maxChunks) {
          final joined = body.join('\n');
          final text = ('$rel\n$joined').length <= maxEmbedChars
              ? '$rel\n$joined'
              : ('$rel\n${joined.substring(0, math.max(0, maxEmbedChars - rel.length - 1))}');
          List<double> vec;
          try {
            vec = await embed(text);
          } catch (_) {
            return null;
          }
          chunks.add(SemanticChunk(
            relPath: rel,
            start: start + 1,
            end: end,
            terms: terms,
            definition: definition,
            snippet: body,
            vector: vec,
          ));
        }
        final next = end - chunkOverlap;
        if (next <= start || end >= lines.length) break;
        start = next;
      }
      return SemanticFileEntry(
        relPath: rel,
        hash: stamp.hash,
        size: stamp.size,
        mtimeMs: stamp.mtimeMs,
        chunks: chunks,
      );
    } on FileSystemException {
      return null;
    }
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final f = File(indexFilePath);
    if (!f.existsSync()) return;
    try {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          if (j['t'] == 'meta') {
            _embedderUsed = j['embedder'] as String?;
            final d = (j['dim'] as num?)?.toInt() ?? 0;
            _dim = d > 0 ? d : null;
            _builtAt = DateTime.tryParse(j['built_at'] as String? ?? '');
          } else if (j['t'] == 'file') {
            final e = SemanticFileEntry.fromJson(j);
            if (e.relPath.isNotEmpty) {
              _entries[_normalize(e.relPath)] = e;
            }
          }
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      _entries.clear();
      _embedderUsed = null;
      _dim = null;
      _builtAt = null;
    }
  }

  void _persist() {
    final dir = Directory(p.dirname(indexFilePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = '$indexFilePath.tmp';
    final buf = StringBuffer();
    buf.writeln(jsonEncode(<String, dynamic>{
      't': 'meta',
      'built_at': _builtAt?.toIso8601String(),
      'embedder': _embedderUsed,
      'dim': _dim ?? 0,
      'files': _entries.length,
      'chunks': chunkCount,
    }));
    final keys = _entries.keys.toList()..sort();
    for (final k in keys) {
      buf.writeln(jsonEncode(_entries[k]!.toJson()));
    }
    try {
      File(tmp).writeAsStringSync(buf.toString(), flush: true);
      File(tmp).renameSync(indexFilePath);
    } on FileSystemException {
      try {
        final t = File(tmp);
        if (t.existsSync()) t.deleteSync();
      } catch (_) {}
    }
  }

  List<String> _collectFiles(String startPath) {
    final out = <String>[];
    void walk(String dirPath) {
      if (out.length >= maxFiles) return;
      final dir = Directory(dirPath);
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        if (out.length >= maxFiles) return;
        final leaf = p.basename(e.path);
        if (e is Link) continue;
        if (e is Directory) {
          if (_junkDirs.contains(leaf)) continue;
          walk(e.path);
        } else if (e is File &&
            _codeExts.contains(p.extension(leaf)) &&
            e.lengthSync() <= maxFileSize) {
          out.add(e.path);
        }
      }
    }

    walk(startPath);
    return out;
  }
}

class _FileStamp {
  const _FileStamp({
    required this.hash,
    required this.size,
    required this.mtimeMs,
  });
  final String hash;
  final int size;
  final int mtimeMs;
}

/// S22 — tool `code_semantic`: pencarian kode hybrid BM25 + cosine embedding
/// atas indeks persisten `data/index/code-semantic.jsonl`. Mode `search`
/// (default) otomatis membangun/men-refresh indeks inkremental dengan budget
/// waktu sebelum mencari; `status`/`rebuild` untuk operasi eksplisit.
class SemanticCodeSearchTool implements Tool {
  SemanticCodeSearchTool({
    required this.indexer,
    this.refreshDeadline = const Duration(seconds: 45),
  });

  final SemanticCodeIndexer indexer;
  final Duration refreshDeadline;

  String _fmtHit(SemanticHit h) {
    final c = h.chunk;
    final buffer = StringBuffer(
        '${c.relPath}:${c.start}-${c.end} '
        '(${h.hybrid ? 'hybrid' : 'bm25'}'
        ', rrf ${(h.score * 1000).round() / 1000}'
        '${h.hybrid ? ', cos ${(h.cosineSim * 1000).round() / 1000}' : ''})');
    for (final line in c.snippet.take(3)) {
      buffer.writeln('  ${CodeSearchTool.cap(line, 160)}');
    }
    buffer.writeln('  ---');
    return buffer.toString();
  }

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'code_semantic',
        description:
            'Pencarian kode semantik hybrid di workspace: BM25-lite + cosine '
            'embedding (dari memory.embed bila aktif; fallback hashing offline '
            'deterministik — bukan model semantik) dipadukan Reciprocal Rank '
            'Fusion atas indeks persisten data/index/code-semantic.jsonl. '
            'Indeks di-refresh inkremental (hash sha256 per file) dengan '
            'budget waktu. Read-only.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Kata kunci/frasa (maks 256 karakter).',
            },
            'path': {
              'type': 'string',
              'description': 'Filter hasil ke prefix path relatif (default ".").',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maksimum hasil (default 10, maks 30).',
            },
            'mode': {
              'type': 'string',
              'enum': ['search', 'status', 'rebuild'],
              'description':
                  'search (default), status ringkas, atau rebuild penuh.',
            },
          },
          'required': ['query'],
        },
        risk: 'low',
        parallelSafe: true,
        timeoutSec: 120,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final mode = (args['mode'] as String?)?.trim() ?? 'search';
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty || query.length > 256) {
      return const ToolResult(
        callId: '',
        content: 'error: query wajib diisi (1..256 karakter)',
        isError: true,
      );
    }
    final rel = (args['path'] as String?)?.trim() ?? '.';
    var limit = (args['limit'] as num?)?.toInt() ?? 10;
    if (limit < 1) limit = 1;
    if (limit > 30) limit = 30;
    final resolved = PathSafety.resolveInRoot(indexer.workspaceRoot, rel);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'Path di luar workspace',
        isError: true,
      );
    }

    if (mode == 'status') {
      final st = await indexer.status();
      return ToolResult(
          callId: '', content: 'code_semantic status: ${jsonEncode(st)}');
    }
    if (mode == 'rebuild') {
      final st = await indexer.refresh(deadline: const Duration(minutes: 3));
      return ToolResult(
          callId: '', content: 'code_semantic rebuild: ${jsonEncode(st)}');
    }

    if (!indexer.built) {
      final built = await indexer.refresh(deadline: refreshDeadline);
      if ((built['chunks'] as int? ?? 0) == 0) {
        return ToolResult(
          callId: '',
          content: 'tidak ada file kode untuk diindeks: ${jsonEncode(built)}',
        );
      }
    }

    final hits = await indexer.search(
      query,
      pathPrefix: rel == '.' ? null : rel,
      limit: limit,
    );
    if (hits.isEmpty) {
      return ToolResult(callId: '', content: 'tidak ada hasil untuk "$query"');
    }
    final buffer = StringBuffer(
        'code_semantic: "$query" -> ${hits.length} hasil '
        '(embedder: ${indexer.embedderLabel})\n');
    for (final h in hits) {
      buffer.writeln(_fmtHit(h));
    }
    return ToolResult(callId: '', content: buffer.toString().trim());
  }
}
