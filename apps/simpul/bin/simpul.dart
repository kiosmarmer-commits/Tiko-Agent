import 'dart:convert';
import 'dart:io';

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
      case 'bench':
        await _bench(rest);
      case 'eval':
        await _eval(rest);
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
  simpul index <vault> [--out DIR]
      Indeks seluruh vault (default: <vault>/.simpul). Backend SQLite bila
      tersedia, otomatis fallback ke JSON.
  simpul search <vault> "kueri" [--limit N]
      Cari catatan. Dukungan: kata (AND), "frasa", tag:a/b, path:folder,
      prop:kunci=nilai, -kecualikan.
  simpul health <vault>
      Laporan kesehatan: catatan, tautan, tautan rusak, orphan, judul ganda.
  simpul links <vault> <path-catatan>
      Daftar backlink ke sebuah catatan.
  simpul layout <vault> [--iterations N] [--isolate] [--multi-level]
      Tata letak force-directed Barnes-Hut (GRA-L01); posisi JSON per node.
      --isolate menjalankan simulasi di isolate (NFR-S02/S08), --multi-level
      memakai coarsening Louvain (GRA-L04).
  simpul viewport <vault> [--min-x A --min-y B --max-x C --max-y D]
      Culling viewport via quadtree (GRA-R02); node dalam persegi panjang.
  simpul serve <vault> [--token T]
      Server MCP "Simpul Bridge" (AI-44) via stdio JSON-RPC: search,
      semsearch, health, backlinks, read_note, clusters, suggest_links.
  simpul semsearch <vault> "kueri" [--limit N]
      Pencarian semantik atas indeks vektor (.simpul/vectors.json).
  simpul search <vault> "kueri" [--hybrid]
      --hybrid menggabungkan leksikal + vektor dengan RRF (AI-20).
  simpul sync <vault>
      Pembaruan inkremental: hanya file berubah/baru/hapus yang diproses
      (NFR-S05, NFR-08).
  simpul clusters <vault>
      Deteksi komunitas Louvain (GRA-L05); id komunitas per node.
  simpul suggest-links <vault> [--limit N] [--min-score S]
      Saran tautan antar catatan serupa yang belum tertaut (AI-25).
  simpul bench <vault> [--iterations N]
      Benchmark scan/index/search/backlink/CSR/inkremental/vektor (BM-02..07).
  simpul eval [--embedder hashing|ollama] [--model M] [--base-url U]
              [--dim N] [--k K]
      Evaluasi retrieval korpus AI-E01: recall@k dan MRR (AI-E02). Default
      embedder hashing (deterministik, tanpa jaringan); ollama butuh server
      lokal berjalan (AI-03).
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

Future<VaultIndex> _openIndex(String vault, String? outDir) async {
  final file = _resolveIndexFile(vault, outDir);
  if (p.extension(file.path) == '.json') {
    return JsonVaultIndex(file.path);
  }
  final sqlite = SqliteVaultIndex.tryOpen(file.path);
  if (sqlite != null) return sqlite;
  return JsonVaultIndex(p.setExtension(file.path, '.json'));
}

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

Future<void> _index(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {'embed'});
  final outDir = opts['out'];
  final watch = Stopwatch()..start();
  final notes = await VaultScanner.scan(vault);
  final scanned = watch.elapsedMilliseconds;
  final file = _resolveIndexFile(vault, outDir);
  final sqlite = SqliteVaultIndex.tryOpen(file.path);
  final VaultIndex index = sqlite ??
      JsonVaultIndex(p.setExtension(file.path, '.json'));
  try {
    await index.replaceAll(notes.map((n) => n.toIndexed()).toList());
  } finally {
    await index.close();
  }
  watch.stop();

  var embedMs = 0;
  var chunkCount = 0;
  if (opts['embed'] == 'true') {
    final embedWatch = Stopwatch()..start();
    chunkCount = await _buildSemanticIndex(vault, notes, outDir);
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
    },
  }));
}

Future<int> _buildSemanticIndex(
  String vault,
  List<ScannedNote> notes,
  String? outDir,
) async {
  final dir = outDir ?? p.join(vault, '.simpul');
  final semantic = InMemorySemanticIndex(
    HashingEmbedder(),
    filePath: p.join(dir, 'vectors.json'),
  );
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
  try {
    await semantic.replaceAll(chunks);
  } finally {
    await semantic.close();
  }
  return chunks.length;
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
      hits = await _hybridSearch(vault, index, query, limit, opts['out']);
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
  String? outDir,
) async {
  final dir = outDir ?? p.join(vault, '.simpul');
  final vectorsFile = File(p.join(dir, 'vectors.json'));
  if (!vectorsFile.existsSync()) {
    throw StateError(
      'indeks vektor belum ada — jalankan: simpul index "$vault" --embed',
    );
  }
  final embedder = HashingEmbedder();
  final semantic = InMemorySemanticIndex(
    embedder,
    filePath: vectorsFile.path,
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
  final opts = _options(args, {'isolate', 'multi-level'});
  final iterations = int.parse(opts['iterations'] ?? '300');
  final notes = await VaultScanner.scan(vault);
  final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
  final config = ForceLayoutConfig(maxIterations: iterations);
  final result = switch ((opts['isolate'], opts['multi-level'])) {
    ('true', _) => await IsolateLayout.simulate(graph, config: config),
    (_, 'true') => MultiLevelLayout.simulate(graph, config: config),
    _ => ForceLayout.simulate(graph, config: config),
  };
  stdout.writeln(jsonEncode({
    'iterations': result.iterations,
    'final_energy': result.finalEnergy,
    'slept': result.slept,
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
  final embedder = HashingEmbedder();
  final semantic = InMemorySemanticIndex(
    embedder,
    filePath: vectorsFile.path,
  );
  try {
    final hits = await semantic.search(
      embedder.embed(query),
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
  final VaultIndex index =
      SqliteVaultIndex.tryOpen(file.path) ?? JsonVaultIndex(p.setExtension(file.path, '.json'));
  try {
    final result = await VaultSync.apply(index, vault);
    stdout.writeln(jsonEncode({
      'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
      ...result.toJson(),
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
