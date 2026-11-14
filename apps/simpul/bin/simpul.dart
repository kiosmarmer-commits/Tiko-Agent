import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:simpul/simpul.dart' show SimpulBridge;
import 'package:simpul_core/simpul_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(2);
  }
  final command = args.first;
  final rest = args.sublist(1);
  try {
    switch (command) {
      case 'generate':
        await _generate(rest);
      case 'index':
        await _index(rest);
      case 'search':
        await _search(rest);
      case 'health':
        await _health(rest);
      case 'links':
        await _links(rest);
      case 'layout':
        await _layout(rest);
      case 'viewport':
        await _viewport(rest);
      case 'serve':
        await _serve(rest);
      case 'semsearch':
        await _semsearch(rest);
      case 'sync':
        await _sync(rest);
      case 'clusters':
        await _clusters(rest);
      case 'suggest-links':
        await _suggestLinks(rest);
      case 'suggest-tags':
        await _suggestTags(rest);
      case 'bench':
        await _bench(rest);
      case 'eval':
        await _eval(rest);
      case 'lock':
        await _lock(rest);
      case 'unlock':
        await _unlock(rest);
      case 'vault-status':
        await _vaultStatus(rest);
      case '--help' || 'help' || '-h':
        _usage();
      default:
        stderr.writeln('perintah tidak dikenal: $command');
        _usage();
        exit(2);
    }
  } on ArgumentError catch (e) {
    stderr.writeln('argumen tidak valid: ${e.message}');
    exit(2);
  } catch (e) {
    stderr.writeln('gagal: $e');
    exit(1);
  }
}

void _usage() {
  stderr.writeln('''
Simpul — indeks vault Markdown lokal-first (kompatibel Obsidian).

Penggunaan:
  simpul generate --notes N --seed S --out DIR [--attachments N]
      Buat vault sintetis deterministik untuk benchmark (BM-01).
  simpul index <vault> [--out DIR] [--embed] [--embedder hashing|ollama]
                [--model M] [--base-url U] [--dim N]
      Indeks seluruh vault (default: <vault>/.simpul). Backend SQLite bila
      tersedia, otomatis fallback ke JSON. --embed membangun indeks vektor;
      --embedder ollama memakai server Ollama lokal (AI-03).
  simpul search <vault> "kueri" [--limit N]
      Cari catatan. Dukungan: kata (AND), "frasa", tag:a/b, path:folder,
      prop:kunci=nilai, -kecualikan.
  simpul health <vault>
      Laporan kesehatan: catatan, tautan, tautan rusak, orphan, judul ganda.
  simpul links <vault> <path-catatan>
      Daftar backlink ke sebuah catatan.
  simpul layout <vault> [--iterations N] [--isolate] [--multi-level]
                [--no-cache]
      Tata letak force-directed Barnes-Hut (GRA-L01); posisi JSON per node.
      --isolate menjalankan simulasi di isolate (NFR-S02/S08), --multi-level
      memakai coarsening Louvain (GRA-L04). Hasil dicache ber-versi dan
      dipakai sebagai warm start (GRA-L02, NFR-S09); --no-cache mematikan.
  simpul viewport <vault> [--min-x A --min-y B --max-x C --max-y D]
      Culling viewport via quadtree (GRA-R02); node dalam persegi panjang.
  simpul serve <vault> [--token T]
      Server MCP "Simpul Bridge" (AI-44) via stdio JSON-RPC: search,
      semsearch, health, backlinks, read_note, clusters, suggest_links.
  simpul semsearch <vault> "kueri" [--limit N] [--embedder ollama]
      Pencarian semantik atas indeks vektor (.simpul/vectors.json); model
      kueri harus sama dengan model indeks (fail-closed, AI-13).
  simpul search <vault> "kueri" [--hybrid] [--embedder ollama]
      --hybrid menggabungkan leksikal + vektor dengan RRF (AI-20).
  simpul sync <vault> [--embedder ollama]
      Pembaruan inkremental: hanya file berubah/baru/hapus yang diproses
      (NFR-S05, NFR-08); vektor chunk yang berubah ikut diperbarui bila
      indeks vektor ada dan modelnya cocok.
  simpul clusters <vault>
      Deteksi komunitas Louvain (GRA-L05); id komunitas per node.
  simpul suggest-links <vault> [--limit N] [--min-score S]
      Saran tautan antar catatan serupa yang belum tertaut (AI-25).
  simpul suggest-tags <vault> [--limit N] [--min-score S]
      Saran tag per catatan dari centroid tag yang sudah ada (AI-26);
      saran saja — penerapan selalu butuh persetujuan manusia.
  simpul bench <vault> [--iterations N]
      Benchmark scan/index/search/backlink/CSR/inkremental/vektor (BM-02..07).
  simpul eval [--embedder hashing|ollama] [--model M] [--base-url U]
              [--dim N] [--k K]
      Evaluasi retrieval korpus AI-E01: recall@k dan MRR (AI-E02). Default
      embedder hashing (deterministik, tanpa jaringan); ollama butuh server
      lokal berjalan (AI-03).
  simpul lock <vault>
      Enkripsi indeks (mode M1, SEC-01/10/11/12): index.json, vectors.json,
      graph_cache.json dienkripsi XChaCha20-Poly1305 (SEC-03) dengan kunci
      vault terbungkus Argon2id (SEC-05/07); file .md tetap polos. Wajib
      SIMPUL_PASSWORD. Backend sqlite ditolak (SQLCipher belum didukung).
  simpul unlock <vault>
      Dekripsi balik indeks dan hapus crate kunci + penanda mode. Wajib
      SIMPUL_PASSWORD.
  simpul vault-status <vault>
      Status enkripsi vault: mode, parameter KDF, daftar file terenkripsi.
      Perintah lain membaca SIMPUL_PASSWORD otomatis saat vault terkunci;
      tanpa password, operasi gagal fail-closed (SEC-16: kunci hanya hidup
      di memori selama proses berjalan).
''');
}

Map<String, String> _options(List<String> args, Set<String> flags) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final key = arg.substring(2);
    if (flags.contains(key)) {
      values[key] = 'true';
      continue;
    }
    if (i + 1 >= args.length) {
      throw ArgumentError('opsi --$key butuh nilai');
    }
    values[key] = args[++i];
  }
  return values;
}

String _positional(List<String> args) =>
    args.where((a) => !a.startsWith('--')).firstOrNull ??
    (throw ArgumentError('path vault wajib diisi'));

File _resolveIndexFile(String vault, String? outDir) {
  final dir = outDir ?? p.join(vault, '.simpul');
  final sqlite = p.join(dir, 'index.db');
  final json = p.join(dir, 'index.json');
  if (File(sqlite).existsSync()) return File(sqlite);
  if (File(json).existsSync()) return File(json);
  return File(sqlite);
}

String? _passwordFromEnv() {
  final password = Platform.environment['SIMPUL_PASSWORD'];
  return (password == null || password.isEmpty) ? null : password;
}

/// Opens the vault key crate when the vault is locked (mode marker present);
/// returns null for a plain M0 vault. Locked without SIMPUL_PASSWORD fails
/// closed (SEC-16).
Future<VaultCrypto?> _vaultCryptoFor(String vault) async {
  final modeFile = File(p.join(vault, '.simpul', 'vault-mode.json'));
  if (!modeFile.existsSync()) return null;
  final password = _passwordFromEnv();
  if (password == null) {
    throw VaultCryptoException(
      'vault terkunci \u2014 set SIMPUL_PASSWORD atau jalankan: simpul unlock <vault>',
    );
  }
  final crateFile = File(p.join(vault, '.simpul', 'vault-key.crate'));
  if (!crateFile.existsSync()) {
    throw VaultCryptoException(
      'crate kunci vault tidak ditemukan: ${crateFile.path}',
    );
  }
  return VaultCrypto.open(crateFile.readAsBytesSync(), password: password);
}

Future<VaultIndex> _openIndexFile(String vault, File file) async {
  final crypto = await _vaultCryptoFor(vault);
  if (p.extension(file.path) == '.json') {
    return JsonVaultIndex(file.path, crypto: crypto);
  }
  if (crypto != null) {
    throw VaultCryptoException(
      'backend sqlite belum didukung pada vault terenkripsi '
      '(SQLCipher belum tersedia) \u2014 pakai backend JSON',
    );
  }
  final sqlite = SqliteVaultIndex.tryOpen(file.path);
  if (sqlite != null) return sqlite;
  return JsonVaultIndex(p.setExtension(file.path, '.json'));
}

Future<VaultIndex> _openIndex(String vault, String? outDir) async =>
    _openIndexFile(vault, _resolveIndexFile(vault, outDir));

Future<void> _generate(List<String> args) async {
  final opts = _options(args, {});
  final notes = int.parse(opts['notes'] ?? '100');
  final seed = int.parse(opts['seed'] ?? '42');
  final out = opts['out'] ??
      (throw ArgumentError('opsi --out wajib diisi, contoh: --out vault-demo'));
  final attachments = int.parse(opts['attachments'] ?? '0');
  final manifest = await VaultGenerator(seed: seed).generate(
    out,
    notes,
    attachments: attachments,
  );
  stdout.writeln(jsonEncode(manifest.toJson()));
}

OllamaEmbedder? _ollamaFromOptions(Map<String, String> opts) {
  if (opts['embedder'] != 'ollama') return null;
  return OllamaEmbedder(
    model: opts['model'] ?? 'nomic-embed-text',
    baseUrl: opts['base-url'] ?? 'http://localhost:11434',
    dimension: opts['dim'] == null ? null : int.parse(opts['dim']!),
  );
}

/// Batch-embeds [texts] through an async embedder and wraps the results in a
/// sync [ReplayEmbedder] so existing sync call sites keep working (AI-03,
/// AI-12).
Future<ReplayEmbedder> _replayEmbedder(
  OllamaEmbedder ollama,
  List<String> texts,
) async {
  const batchSize = 32;
  final vectors = <String, Float32List>{};
  for (var i = 0; i < texts.length; i += batchSize) {
    final batch = texts.sublist(i, i + batchSize > texts.length ? texts.length : i + batchSize);
    final embedded = await ollama.embedBatch(batch);
    for (var j = 0; j < batch.length; j++) {
      vectors[batch[j]] = embedded[j];
    }
  }
  return ReplayEmbedder(
    modelVersion: ollama.modelVersion,
    dimension: ollama.dimension,
    vectors: vectors,
  );
}

/// Fail-closed model check (AI-13): the stored vector file must match the
/// requested embedder before any search opens it.
void _checkVectorModel(
  String vectorsPath,
  String expectedModel, {
  VaultCrypto? crypto,
}) {
  final stored = InMemorySemanticIndex.storedModelVersion(vectorsPath, crypto: crypto);
  if (stored != null && stored != expectedModel) {
    throw StateError(
      'indeks vektor dibuat dengan model "$stored", bukan "$expectedModel" '
      '\u2014 jalankan ulang: simpul index <vault> --embed --embedder ...',
    );
  }
}

Future<void> _index(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {'embed'});
  final outDir = opts['out'];
  final watch = Stopwatch()..start();
  final notes = await VaultScanner.scan(vault);
  final scanned = watch.elapsedMilliseconds;
  final file = _resolveIndexFile(vault, outDir);
  final VaultIndex index = await _openIndexFile(vault, file);
  final crypto = await _vaultCryptoFor(vault);
  try {
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
  } finally {
    await index.close();
  }
  watch.stop();

  var embedMs = 0;
  var chunkCount = 0;
  String? model;
  if (opts['embed'] == 'true') {
    final embedWatch = Stopwatch()..start();
    final (builtChunks, builtModel) =
        await _buildSemanticIndex(vault, notes, outDir, opts, crypto);
    chunkCount = builtChunks;
    model = builtModel;
    embedMs = embedWatch.elapsedMilliseconds;
  }
  stdout.writeln(jsonEncode({
    'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
    'index_file': index is SqliteVaultIndex ? file.path : p.setExtension(file.path, '.json'),
    'notes': notes.length,
    'scan_ms': scanned,
    'index_ms': watch.elapsedMilliseconds - scanned,
    if (embedMs > 0 || chunkCount > 0) ...{
      'embedded_chunks': chunkCount,
      'embed_ms': embedMs,
      if (model != null) 'model': model,
    },
  }));
}

Future<(int, String)> _buildSemanticIndex(
  String vault,
  List<ScannedNote> notes,
  String? outDir,
  Map<String, String> opts,
  VaultCrypto? crypto,
) async {
  final dir = outDir ?? p.join(vault, '.simpul');
  final chunks = <ChunkInput>[];
  for (final note in notes) {
    for (var i = 0; i < note.parsed.chunks.length; i++) {
      final chunk = note.parsed.chunks[i];
      chunks.add(ChunkInput(
        notePath: note.path,
        ord: i,
        headingPath: chunk.headingPath,
        text: chunk.text,
        hash: '${note.contentHash}:$i',
      ));
    }
  }
  final ollama = _ollamaFromOptions(opts);
  final EmbeddingProvider embedder;
  if (ollama != null) {
    embedder = await _replayEmbedder(
      ollama,
      [for (final chunk in chunks) chunk.text],
    );
  } else {
    embedder = HashingEmbedder();
  }
  final semantic = InMemorySemanticIndex(
    embedder,
    filePath: p.join(dir, 'vectors.json'),
    crypto: crypto,
  );
  try {
    await semantic.replaceAll(chunks);
  } finally {
    await semantic.close();
  }
  return (chunks.length, embedder.modelVersion);
}

Future<void> _search(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul search <vault> "kueri"');
  }
  final vault = positional[0];
  final query = positional[1];
  final opts = _options(args, {'hybrid'});
  final limit = int.parse(opts['limit'] ?? '20');
  final index = await _openIndex(vault, opts['out']);
  try {
    List<SearchHit> hits;
    if (opts['hybrid'] == 'true') {
      hits = await _hybridSearch(vault, index, query, limit, opts);
    } else {
      hits = await index.search(query, limit: limit);
    }
    stdout.writeln(jsonEncode({
      'query': query,
      'hits': hits
          .map((h) => {
                'path': h.path,
                'title': h.title,
                'score': h.score,
                'heading_path': h.headingPath,
                'snippet': h.snippet,
              })
          .toList(),
    }));
  } finally {
    await index.close();
  }
}

Future<List<SearchHit>> _hybridSearch(
  String vault,
  VaultIndex index,
  String query,
  int limit,
  Map<String, String> opts,
) async {
  final dir = opts['out'] ?? p.join(vault, '.simpul');
  final vectorsFile = File(p.join(dir, 'vectors.json'));
  if (!vectorsFile.existsSync()) {
    throw StateError(
      'indeks vektor belum ada — jalankan: simpul index "$vault" --embed',
    );
  }
  final ollama = _ollamaFromOptions(opts);
  final expectedModel = ollama?.modelVersion ?? HashingEmbedder().modelVersion;
  final crypto = await _vaultCryptoFor(vault);
  _checkVectorModel(vectorsFile.path, expectedModel, crypto: crypto);
  final EmbeddingProvider embedder;
  if (ollama != null) {
    final queryVec = await ollama.embed(query);
    embedder = ReplayEmbedder(
      modelVersion: ollama.modelVersion,
      dimension: ollama.dimension,
      vectors: {query: queryVec},
    );
  } else {
    embedder = HashingEmbedder();
  }
  final semantic = InMemorySemanticIndex(
    embedder,
    filePath: vectorsFile.path,
    crypto: crypto,
  );
  try {
    return await HybridSearcher(
      index: index,
      semantic: semantic,
      embedder: embedder,
    ).search(query, limit: limit);
  } finally {
    await semantic.close();
  }
}

Future<void> _layout(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {'isolate', 'multi-level', 'no-cache'});
  final iterations = int.parse(opts['iterations'] ?? '300');
  final notes = await VaultScanner.scan(vault);
  final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
  final config = ForceLayoutConfig(maxIterations: iterations);
  final multiLevel = opts['multi-level'] == 'true';
  final kind = layoutCacheKind(multiLevel: multiLevel);
  final version =
      layoutCacheVersion(graph, iterations: iterations, multiLevel: multiLevel);
  final cache = openVaultCacheStore(
    vault,
    outDir: opts['out'],
    crypto: await _vaultCryptoFor(vault),
  );
  Map<String, Object?>? cached;
  if (cache != null && opts['no-cache'] != 'true') {
    try {
      cached = await cache.loadGraphCache(kind: kind, version: version);
    } finally {
      await (cache as VaultIndex).close();
    }
  }
  if (cached != null) {
    applyWarmStart(graph, cached);
  }
  final warm = cached != null && !multiLevel;
  final result = switch ((opts['isolate'], multiLevel)) {
    ('true', _) => await IsolateLayout.simulate(graph, config: config, warmStart: warm),
    (_, true) => MultiLevelLayout.simulate(graph, config: config),
    _ => ForceLayout.simulate(graph, config: config, warmStart: warm),
  };
  final payload = {
    'x': [for (final x in graph.positionsX) x],
    'y': [for (final y in graph.positionsY) y],
  };
  if (cache != null && opts['no-cache'] != 'true') {
    try {
      await cache.saveGraphCache(kind: kind, version: version, payload: payload);
    } finally {
      await (cache as VaultIndex).close();
    }
  }
  stdout.writeln(jsonEncode({
    'iterations': result.iterations,
    'final_energy': result.finalEnergy,
    'slept': result.slept,
    'warm_start': cached != null,
    'nodes': [
      for (var i = 0; i < graph.nodeCount; i++)
        {
          'id': i,
          'path': graph.paths[i],
          'x': graph.positionsX[i],
          'y': graph.positionsY[i],
        },
    ],
  }));
}

/// Deterministic fingerprint, cache versioning, and warm-start helpers live
/// in simpul_core (`layout_cache.dart`) so the Flutter graph view and the CLI
/// share one implementation.

Future<void> _viewport(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final minX = double.parse(opts['min-x'] ?? '-1e9');
  final minY = double.parse(opts['min-y'] ?? '-1e9');
  final maxX = double.parse(opts['max-x'] ?? '1e9');
  final maxY = double.parse(opts['max-y'] ?? '1e9');
  final notes = await VaultScanner.scan(vault);
  final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
  ForceLayout.simulate(graph);
  final tree = QuadtreeIndex.build(graph.positionsX, graph.positionsY);
  final ids = tree.queryRegion(minX, minY, maxX, maxY);
  stdout.writeln(jsonEncode({
    'total': graph.nodeCount,
    'visible': ids.length,
    'nodes': [
      for (final i in ids)
        {
          'id': i,
          'path': graph.paths[i],
          'x': graph.positionsX[i],
          'y': graph.positionsY[i],
        },
    ],
  }));
}

Future<void> _serve(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final bridge = SimpulBridge(vaultDir: vault, token: opts['token']);
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final response = await bridge.handleLine(line);
    if (response.isNotEmpty) stdout.writeln(response);
  }
}

Future<void> _semsearch(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul semsearch <vault> "kueri"');
  }
  final vault = positional[0];
  final query = positional[1];
  final opts = _options(args, {});
  final limit = int.parse(opts['limit'] ?? '20');
  final dir = opts['out'] ?? p.join(vault, '.simpul');
  final vectorsFile = File(p.join(dir, 'vectors.json'));
  if (!vectorsFile.existsSync()) {
    throw StateError(
      'indeks vektor belum ada — jalankan: simpul index "$vault" --embed',
    );
  }
  final ollama = _ollamaFromOptions(opts);
  final expectedModel = ollama?.modelVersion ?? HashingEmbedder().modelVersion;
  final crypto = await _vaultCryptoFor(vault);
  _checkVectorModel(vectorsFile.path, expectedModel, crypto: crypto);
  final EmbeddingProvider embedder;
  final Float32List queryVec;
  if (ollama != null) {
    queryVec = await ollama.embed(query);
    embedder = ReplayEmbedder(
      modelVersion: ollama.modelVersion,
      dimension: ollama.dimension,
      vectors: {query: queryVec},
    );
  } else {
    final hashing = HashingEmbedder();
    queryVec = hashing.embed(query);
    embedder = hashing;
  }
  final semantic = InMemorySemanticIndex(
    embedder,
    filePath: vectorsFile.path,
    crypto: crypto,
  );
  try {
    final hits = await semantic.search(
      queryVec,
      limit: limit,
    );
    stdout.writeln(jsonEncode({
      'query': query,
      'model': embedder.modelVersion,
      'hits': [
        for (final h in hits)
          {
            'path': h.notePath,
            'chunk': h.ord,
            'heading_path': h.headingPath,
            'score': h.score,
          },
      ],
    }));
  } finally {
    await semantic.close();
  }
}

Future<void> _sync(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final file = _resolveIndexFile(vault, opts['out']);
  final VaultIndex index = await _openIndexFile(vault, file);
  final crypto = await _vaultCryptoFor(vault);
  final dir = opts['out'] ?? p.join(vault, '.simpul');
  final vectorsFile = File(p.join(dir, 'vectors.json'));
  var vectorsState = vectorsFile.existsSync() ? 'unchanged' : 'absent';
  try {
    final result = await VaultSync.apply(
      index,
      vault,
      semanticFactory: (changed) async {
        if (!vectorsFile.existsSync()) return null;
        final ollama = _ollamaFromOptions(opts);
        final expectedModel =
            ollama?.modelVersion ?? HashingEmbedder().modelVersion;
        final stored = InMemorySemanticIndex.storedModelVersion(
          vectorsFile.path,
          crypto: crypto,
        );
        if (stored != null && stored != expectedModel) {
          vectorsState = 'skipped_model_mismatch';
          return null;
        }
        final EmbeddingProvider embedder;
        if (ollama != null) {
          embedder = await _replayEmbedder(
            ollama,
            [
              for (final note in changed)
                for (final chunk in note.parsed.chunks) chunk.text,
            ],
          );
        } else {
          embedder = HashingEmbedder();
        }
        vectorsState = 'updated';
        return InMemorySemanticIndex(
          embedder,
          filePath: vectorsFile.path,
          crypto: crypto,
        );
      },
    );
    stdout.writeln(jsonEncode({
      'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
      ...result.toJson(),
      'vectors': vectorsState,
      'detail': {
        'added': result.added,
        'updated': result.updated,
        'removed': result.removed,
      },
    }));
  } finally {
    await index.close();
  }
}

Future<void> _clusters(List<String> args) async {
  final vault = _positional(args);
  final notes = await VaultScanner.scan(vault);
  final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
  final result = CommunityDetector.louvain(graph);
  final counts = <int, int>{};
  for (final c in result.communityOf) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  stdout.writeln(jsonEncode({
    'community_count': result.communityCount,
    'modularity': result.modularity,
    'sizes': {
      for (final key in counts.keys.toList()..sort())
        '$key': counts[key],
    },
    'nodes': [
      for (var i = 0; i < graph.nodeCount; i++)
        {
          'id': i,
          'path': graph.paths[i],
          'community': result.communityOf[i],
        },
    ],
  }));
}

Future<void> _suggestLinks(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final limit = int.parse(opts['limit'] ?? '20');
  final minScore = double.parse(opts['min-score'] ?? '${LinkSuggester.defaultMinScore}');
  final notes = await VaultScanner.scan(vault);
  final suggestions = await LinkSuggester.suggest(
    notes.map((n) => n.toIndexed()).toList(),
    limit: limit,
    minScore: minScore,
  );
  stdout.writeln(jsonEncode({
    'suggestions': [
      for (final s in suggestions)
        {
          'from': s.fromPath,
          'to': s.toPath,
          'score': s.score,
        },
    ],
  }));
}

Future<void> _health(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final index = await _openIndex(vault, opts['out']);
  try {
    final health = await index.health();
    stdout.writeln(jsonEncode({
      'note_count': health.noteCount,
      'link_count': health.linkCount,
      'broken_links': health.brokenLinks,
      'orphans': health.orphans,
      'duplicate_titles': health.duplicateTitles,
    }));
  } finally {
    await index.close();
  }
}

Future<void> _links(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul links <vault> <path-catatan>');
  }
  final vault = positional[0];
  var target = positional[1];
  if (target.startsWith('./')) target = target.substring(2);
  if (target.endsWith('.md')) target = target.substring(0, target.length - 3);
  final opts = _options(args, {});
  final index = await _openIndex(vault, opts['out']);
  try {
    final links = await index.backlinks(target);
    stdout.writeln(jsonEncode({'note': target, 'backlinks': links}));
  } finally {
    await index.close();
  }
}

Future<void> _bench(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final iterations = int.parse(opts['iterations'] ?? '50');
  final report = await BenchmarkRunner().run(
    vault,
    searchIterations: iterations,
  );
  stdout.writeln(jsonEncode(report));
}

Future<void> _suggestTags(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final limit = int.parse(opts['limit'] ?? '5');
  final minScore =
      double.parse(opts['min-score'] ?? '${TagSuggester.defaultMinScore}');
  final notes = await VaultScanner.scan(vault);
  final suggestions = TagSuggester.suggest(
    notes.map((n) => n.toIndexed()).toList(),
    limit: limit,
    minScore: minScore,
  );
  stdout.writeln(jsonEncode({
    'suggestions': [
      for (final s in suggestions)
        {'path': s.path, 'tag': s.tag, 'score': s.score},
    ],
  }));
}

Future<void> _eval(List<String> args) async {
  final opts = _options(args, {});
  final embedder = opts['embedder'] ?? 'hashing';
  final k = int.parse(opts['k'] ?? '5');
  final EvalResult result;
  switch (embedder) {
    case 'hashing':
      result = EvalHarness.run(k: k);
    case 'ollama':
      final ollama = OllamaEmbedder(
        model: opts['model'] ?? 'nomic-embed-text',
        baseUrl: opts['base-url'] ?? 'http://localhost:11434',
        dimension: opts['dim'] == null ? null : int.parse(opts['dim']!),
      );
      result = await EvalHarness.runAsync(embedder: ollama, k: k);
    default:
      throw ArgumentError(
        'embedder tidak dikenal: $embedder (pilihan: hashing, ollama)',
      );
  }
  stdout.writeln(jsonEncode(result.toJson()));
}

const _encryptedIndexFiles = ['index.json', 'vectors.json', 'graph_cache.json'];

Future<void> _lock(List<String> args) async {
  final vault = _positional(args);
  final dir = p.join(vault, '.simpul');
  final modeFile = File(p.join(dir, 'vault-mode.json'));
  if (modeFile.existsSync()) {
    throw StateError('vault sudah terkunci \u2014 jalankan: simpul unlock <vault>');
  }
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk mengenkripsi vault'));
  final indexFile = _resolveIndexFile(vault, null);
  if (p.extension(indexFile.path) == '.db' && indexFile.existsSync()) {
    throw StateError(
      'backend sqlite belum didukung enkripsi (SQLCipher belum tersedia) '
      '\u2014 hapus index.db atau jalankan ulang dengan backend JSON',
    );
  }
  final created = await VaultCrypto.create(password: password);
  final crypto = created.crypto;
  final encrypted = <String>[];
  for (final name in _encryptedIndexFiles) {
    final file = File(p.join(dir, name));
    if (file.existsSync()) {
      await crypto.encryptFileInPlace(file.path);
      encrypted.add(name);
    }
  }
  await File(p.join(dir, 'vault-key.crate'))
      .writeAsBytes(await crypto.sealKeyCrate(password), flush: true);
  await VaultCrypto.writeBytesAtomically(
    modeFile.path,
    utf8.encode(jsonEncode({
      'mode': 'm1',
      'kdf': crypto.kdf.toJson(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    })),
  );
  stdout.writeln(jsonEncode({
    'locked': true,
    'mode': 'm1',
    'kdf': crypto.kdf.toJson(),
    'encrypted': encrypted,
    'key_crate': p.join(dir, 'vault-key.crate'),
  }));
}

Future<void> _unlock(List<String> args) async {
  final vault = _positional(args);
  final dir = p.join(vault, '.simpul');
  final modeFile = File(p.join(dir, 'vault-mode.json'));
  if (!modeFile.existsSync()) {
    throw StateError('vault tidak terkunci');
  }
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk membuka vault'));
  final crateFile = File(p.join(dir, 'vault-key.crate'));
  if (!crateFile.existsSync()) {
    throw VaultCryptoException('crate kunci vault tidak ditemukan: ${crateFile.path}');
  }
  final crypto = await VaultCrypto.open(crateFile.readAsBytesSync(), password: password);
  final decrypted = <String>[];
  for (final name in _encryptedIndexFiles) {
    final file = File(p.join(dir, name));
    if (file.existsSync() && VaultCrypto.isFileEncrypted(file.path)) {
      await crypto.decryptFileInPlace(file.path);
      decrypted.add(name);
    }
  }
  crateFile.deleteSync();
  modeFile.deleteSync();
  stdout.writeln(jsonEncode({
    'unlocked': true,
    'decrypted': decrypted,
  }));
}

Future<void> _vaultStatus(List<String> args) async {
  final vault = _positional(args);
  final dir = p.join(vault, '.simpul');
  final modeFile = File(p.join(dir, 'vault-mode.json'));
  final locked = modeFile.existsSync();
  Map<String, Object?>? kdf;
  if (locked) {
    final decoded = jsonDecode(modeFile.readAsStringSync()) as Map<String, Object?>;
    kdf = (decoded['kdf'] as Map?)?.cast<String, Object?>();
  }
  final files = <String, bool>{
    for (final name in _encryptedIndexFiles)
      name: VaultCrypto.isFileEncrypted(p.join(dir, name)),
  };
  stdout.writeln(jsonEncode({
    'vault': vault,
    'mode': locked ? 'm1' : 'm0',
    'locked': locked,
    if (kdf != null) 'kdf': kdf,
    'files': files,
    'password_available': _passwordFromEnv() != null,
  }));
}
