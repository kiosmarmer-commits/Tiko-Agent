import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:simpul/simpul.dart' show SimpulBridge;
import 'package:simpul_core/simpul_core.dart';
import 'package:simpul/tui/repl.dart';

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
      case 'watch':
        await _watch(rest);
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
      case 'recovery-split':
        await _recoverySplit(rest);
      case 'canvas':
        await _canvas(rest);
      case 'bundle-export':
        await _bundleExport(rest);
      case 'bundle-import':
        await _bundleImport(rest);
      case 'sync-init':
        await _syncInit(rest);
      case 'sync-status':
        await _syncStatus(rest);
      case 'sync-export':
        await _syncExport(rest);
      case 'sync-import':
        await _syncImport(rest);
      case 'tui' || 'repl':
        await _tui(rest);
      case 'ask':
        await _ask(rest);
      case 'suggest-improve':
        await _suggestImprove(rest);
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
  simpul bench <vault> [--iterations N] [--backend auto|json]
      Benchmark scan/index/search/backlink/CSR/inkremental/vektor (BM-02..07).
      Default auto memakai backend sqlite nyata (BM-07) bila libsqlite3/
      libsqlcipher tersedia; --backend json memaksa fallback JSON.
  simpul eval [--embedder hashing|ollama] [--model M] [--base-url U]
              [--dim N] [--k K]
      Evaluasi retrieval korpus AI-E01: recall@k dan MRR (AI-E02). Default
      embedder hashing (deterministik, tanpa jaringan); ollama butuh server
      lokal berjalan (AI-03).
  simpul watch <vault> [--interval-ms N]
      Pantau vault dan jalankan sinkron inkremental otomatis (NFR-S05)
      setiap catatan .md berubah (satu baris JSON per sinkronisasi).
      Folder tersembunyi diabaikan; vault terenkripsi membaca
      SIMPUL_PASSWORD seperti perintah lain.
  simpul lock <vault> [--mode m1|m2|m3] [--folders a,b]
      [--recovery-shares N] [--recovery-threshold K]
      Enkripsi vault bertahap (SEC-01): m1 (default) hanya artefak indeks
      (index.json, vectors.json, graph_cache.json); m2 menambahkan catatan
      .md di folder terpilih; m3 seluruh catatan .md. Semua file dienkripsi
      XChaCha20-Poly1305 (SEC-03) dengan kunci vault terbungkus Argon2id
      (SEC-05/07). Wajib SIMPUL_PASSWORD. m2 butuh --folders (dipisah koma).
      Backend sqlite ditolak (SQLCipher belum didukung). Dengan
      --recovery-shares, share Shamir (SEC-06) dicetak ke stdout untuk
      disimpan offline; default threshold = ceil(N/2).
  simpul unlock <vault> [--recovery-shares s1,s2,...] [--recovery-file path]
      Dekripsi balik indeks dan seluruh catatan terenkripsi, hapus crate
      kunci + penanda mode. Wajib SIMPUL_PASSWORD, atau share pemulihan
      Shamir (SEC-06) via --recovery-shares (dipisah koma) / --recovery-file
      (satu share per baris) bila password hilang.
  simpul recovery-split <vault> [--shares N] [--threshold K]
      Pecahkan kunci vault yang sedang terkunci menjadi N share Shamir
      (SEC-06), threshold K (default ceil(N/2)); satu baris JSON per share
      ke stdout. Wajib SIMPUL_PASSWORD.
  simpul canvas <vault> [--out path] [--iterations N]
      Ekspor graf vault sebagai file JSON Canvas (.canvas) kompatibel
      Obsidian (FR-41): tiap catatan menjadi node "file" dengan posisi
      force layout, tiap tautan menjadi edge, warna per folder. Vault
      terenkripsi membaca SIMPUL_PASSWORD seperti perintah lain.
  simpul bundle-export <vault> [--out path]
      Segel seluruh vault (catatan + artefak indeks) menjadi satu bundle
      terenkripsi end-to-end .simpulbag (SEC-20..22): XChaCha20-Poly1305
      dengan kunci vault terbungkus Argon2id dari SIMPUL_PASSWORD. Pindahkan
      file dengan saluran apa pun; hanya password yang membukanya. Vault
      terkunci membaca SIMPUL_PASSWORD untuk dekripsi in-memory.
  simpul bundle-import <bag> --out <dir>
      Buka bundle .simpulbag dengan SIMPUL_PASSWORD dan tulis vault di <dir>
      (plaintext m0 — jalankan `simpul lock` di tujuan bila perlu). Entri
      dengan path traversal (.., absolut) ditolak sebelum ditulis.
  simpul sync-init <vault> --device ID
      Inisialisasi jurnal sinkronisasi dua arah (.simpul/sync/journal.json)
      untuk perangkat ini. Jalan lagi kapan pun untuk memindai ulang;
      file yang hilang dari disk otomatis menjadi tombstone hapus.
  simpul sync-status <vault>
      Ringkasan jurnal: deviceId, revisi, jumlah file, tombstone, peer.
  simpul sync-export <vault> (--peer ID | --peer-journal FILE)
                     [--out path] [--encrypt]
      Ekspor delta terenkripsi SMPLDLT1 berisi hanya file yang berbeda dari
      jurnal peer (dua arah, offline). --encrypt menyegel delta dengan
      SIMPUL_PASSWORD; tanpa flag delta polos untuk transfer lokal.
  simpul sync-import <vault> <delta> [--strategy keep-both|newest|theirs|ours]
      Terapkan delta dari perangkat lain. Konflik (dua sisi berubah) tidak
      pernah menimpa diam-diam: keep-both (default) menulis file
      n.conflict-<device>-<stamp>.md, newest memilih mtime terbaru, ours
      mempertahankan lokal, theirs menerima delta.
  simpul tui <vault>
      Antarmuka terminal interaktif (paritas Hermes): editing per karakter
      dengan riwayat (↑/↓), autocomplete Tab untuk perintah dan path catatan,
      multiline (akhiri baris dengan backslash atau blok /begin … /end), pintasan
      Ctrl+A/E/K/U/W, warna ANSI (hormati NO_COLOR). Fallback mode baris
      bila terminal tidak mendukung raw mode.
  simpul vault-status <vault>
      Status enkripsi vault: mode, parameter KDF, folder terenkripsi (m2),
      jumlah catatan terenkripsi, dan daftar file indeks.
      Perintah lain membaca SIMPUL_PASSWORD otomatis saat vault terkunci;
      tanpa password, operasi gagal fail-closed (SEC-16: kunci hanya hidup
      di memori selama proses berjalan).
  simpul ask <vault> "pertanyaan" [--limit N] [--budget N] [--llm]
                [--llm-model M] [--llm-base-url U] [--embedder ollama]
      "Tanya vault" (RAG, AI-21): bukti diambil leksikal + semantik (RRF),
      dirakit dengan sitasi [n] ke catatan + heading dalam anggaran token
      (AI-23). Tanpa --llm jawaban ekstraktif (bukti apa adanya); dengan
      --llm model lokal Ollama menyusun jawaban ber-sitasi. Bukti kurang →
      "tidak ditemukan" (AI-22) — tidak pernah mengarang.
  simpul suggest-improve <vault> <path> --op ringkasan|tulis-ulang|terjemahan|tugas
                [--lang KODE] [--llm-model M] [--llm-base-url U]
      Saran perbaikan catatan dari LLM lokal (AI-24): ringkasan, tulis
      ulang, terjemahan, atau ekstraksi tugas. Hasil hanya SARAN (tidak
      pernah menimpa catatan; penerapan = keputusan manusia, AI-41).
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
  final sqlite =
      SqliteVaultIndex.tryOpen(file.path, vaultKey: crypto?.vaultKeyBytes());
  if (sqlite != null) return sqlite;
  if (crypto != null) {
    throw VaultCryptoException(
      'vault terkunci dan backend sqlite tidak tersedia \u2014 '
      'set SIMPUL_PASSWORD atau pakai backend JSON',
    );
  }
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
  final crypto = await _vaultCryptoFor(vault);
  final notes = await VaultScanner.scan(vault, crypto: crypto);
  final scanned = watch.elapsedMilliseconds;
  final file = _resolveIndexFile(vault, outDir);
  final VaultIndex index = await _openIndexFile(vault, file);
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
  final opts = _options(args, {'hybrid', 'prefilter'});
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
  Set<String>? prefilterPaths;
  if (opts['prefilter'] == 'true') {
    prefilterPaths = await lexicalPrefilter(index, query);
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
    ).search(query, limit: limit, allowedPaths: prefilterPaths);
  } finally {
    await semantic.close();
  }
}

Future<void> _layout(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {'isolate', 'multi-level', 'no-cache'});
  final iterations = int.parse(opts['iterations'] ?? '300');
  final notes = await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
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
  final notes = await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
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
  final opts = _options(args, {'prefilter'});
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
  Set<String>? prefilterPaths;
  var prefilterCount = 0;
  if (opts['prefilter'] == 'true') {
    final lexicalIndex = await _openIndex(vault, opts['out']);
    try {
      prefilterPaths = await lexicalPrefilter(lexicalIndex, query);
      prefilterCount = prefilterPaths.length;
    } finally {
      await lexicalIndex.close();
    }
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
      allowedPaths: prefilterPaths,
    );
    stdout.writeln(jsonEncode({
      'query': query,
      'model': embedder.modelVersion,
      if (opts['prefilter'] == 'true')
        'prefilter_candidates': prefilterCount,
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
  stdout.writeln(jsonEncode(await _syncOnce(vault, opts)));
}

/// Perintah `watch`: sinkron inkremental otomatis setiap ada perubahan
/// catatan (NFR-S05) dengan debounce, sampai proses dihentikan.
Future<void> _watch(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final intervalMs = int.parse(opts['interval-ms'] ?? '1000');
  stdout.writeln(jsonEncode({
    'watching': vault,
    'interval_ms': intervalMs,
  }));
  await stdout.flush();
  final watcher = VaultWatcher(vault);
  await for (final batch in watcher.batches(interval: Duration(milliseconds: intervalMs))) {
    final payload = await _syncOnce(vault, opts);
    stdout.writeln(jsonEncode({
      'changed': batch.paths,
      'at': batch.at.toUtc().toIso8601String(),
      'sync': payload,
    }));
    await stdout.flush();
  }
}

Future<Map<String, Object?>> _syncOnce(String vault, Map<String, String> opts) async {
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
      crypto: crypto,
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
    return {
      'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
      ...result.toJson(),
      'vectors': vectorsState,
      'detail': {
        'added': result.added,
        'updated': result.updated,
        'removed': result.removed,
      },
    };
  } finally {
    await index.close();
  }
}

Future<void> _clusters(List<String> args) async {
  final vault = _positional(args);
  final notes = await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
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
  final notes = await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
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
  final backend = opts['backend'] ?? 'auto';
  final report = await BenchmarkRunner(
    indexFactory: backend == 'json' ? (path) => JsonVaultIndex(path) : null,
  ).run(
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
  final notes = await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
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

Future<void> _lock(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk mengenkripsi vault'));
  final recoveryCount = int.tryParse(opts['recovery-shares'] ?? '');
  final result = await VaultModes.lock(
    vault,
    password: password,
    mode: opts['mode'] ?? 'm1',
    folders: [
      for (final folder in (opts['folders'] ?? '').split(','))
        if (folder.trim().isNotEmpty) folder.trim(),
    ],
    recoveryShares: recoveryCount,
    recoveryThreshold: int.tryParse(opts['recovery-threshold'] ?? ''),
  );
  stdout.writeln(jsonEncode({
    'locked': true,
    'mode': result.mode,
    'kdf': result.kdf,
    'encrypted': result.encrypted,
    'key_crate': result.keyCratePath,
    if (result.folders.isNotEmpty) 'folders': result.folders,
    if (result.shares.isNotEmpty) 'recovery_shares': result.shares,
  }));
  if (result.shares.isNotEmpty) {
    stderr.writeln(
      'SIMPER: simpan ${result.shares.length} share pemulihan di tempat '
      'terpisah (SEC-06) \u2014 share merekonstruksi kunci vault tanpa password.',
    );
  }
}

Future<void> _unlock(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final shares = <String>[
    for (final share in (opts['recovery-shares'] ?? '').split(','))
      if (share.trim().isNotEmpty) share.trim(),
  ];
  final recoveryFile = opts['recovery-file'];
  if (recoveryFile != null) {
    shares.addAll([
      for (final line in File(recoveryFile).readAsLinesSync())
        if (line.trim().isNotEmpty) line.trim(),
    ]);
  }
  final password = _passwordFromEnv();
  if (password == null && shares.isEmpty) {
    throw ArgumentError(
      'set SIMPUL_PASSWORD atau --recovery-shares/--recovery-file '
      'untuk membuka vault',
    );
  }
  final result = await VaultModes.unlock(
    vault,
    password: password,
    recoveryShares: shares,
  );
  stdout.writeln(jsonEncode({
    'unlocked': true,
    if (shares.isNotEmpty) 'via': 'recovery-shares',
    'decrypted': result.decrypted,
  }));
}

/// SEC-06: splits the current vault key into Shamir shares while the vault
/// is locked; shares print to stdout (store them offline).
Future<void> _recoverySplit(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final shares = int.parse(opts['shares'] ?? '5');
  final threshold = int.parse(opts['threshold'] ?? (shares ~/ 2 + 1).toString());
  final crateFile = File(p.join(vault, '.simpul', 'vault-key.crate'));
  if (!crateFile.existsSync()) {
    throw StateError('vault tidak terkunci \u2014 recovery-split hanya untuk vault terkunci');
  }
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk membaca crate kunci'));
  final crypto =
      await VaultCrypto.open(crateFile.readAsBytesSync(), password: password);
  final split = VaultRecovery.splitKey(
    crypto.vaultKeyBytes(),
    shares: shares,
    threshold: threshold,
  );
  for (var i = 0; i < split.length; i++) {
    stdout.writeln(jsonEncode({'share': i + 1, 'of': shares, 'value': split[i]}));
  }
  stderr.writeln(
    'SIMPER: simpan tiap share di lokasi terpisah; butuh $threshold dari '
    '$shares share untuk pemulihan tanpa password.',
  );
}

/// FR-41: exports the vault graph as an Obsidian-compatible JSON Canvas
/// (.canvas) file, laid out by the force layout, colored per folder.
Future<void> _canvas(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final out = opts['out'] ?? p.join(vault, 'graph.canvas');
  final iterations = int.parse(opts['iterations'] ?? '200');
  final notes =
      await VaultScanner.scan(vault, crypto: await _vaultCryptoFor(vault));
  final document = VaultCanvas.fromNotes(
    notes.map((n) => n.toIndexed()).toList(),
    config: ForceLayoutConfig(maxIterations: iterations),
  );
  await VaultCrypto.writeBytesAtomically(out, utf8.encode(document.encode()));
  stdout.writeln(jsonEncode({
    'canvas': out,
    'nodes': document.nodes.length,
    'edges': document.edges.length,
  }));
}

/// SEC-20..22: seals the whole vault (notes + index artifacts) into one
/// portable encrypted bundle; plaintext never touches the wire.
Future<void> _bundleExport(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk menyegel bundle'));
  final out = opts['out'] ?? '$vault.simpulbag';
  final result = await VaultBundle.exportBundle(
    vault,
    password: password,
    outPath: out,
    crypto: await _vaultCryptoFor(vault),
  );
  stdout.writeln(jsonEncode({
    'bundle': result.path,
    'files': result.fileCount,
    'bytes': result.sizeBytes,
  }));
}

/// SEC-20..22: opens an encrypted bundle with SIMPUL_PASSWORD and unpacks
/// the vault at --out (plaintext m0; jalankan `simpul lock` di tujuan bila
/// perlu).
Future<void> _bundleImport(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    throw ArgumentError('pemakaian: simpul bundle-import <bag> --out <dir>');
  }
  final opts = _options(args, {});
  final password = _passwordFromEnv() ??
      (throw ArgumentError('set SIMPUL_PASSWORD untuk membuka bundle'));
  final out = opts['out'] ??
      (throw ArgumentError('opsi --out wajib diisi, contoh: --out vault-restored'));
  final result = await VaultBundle.importBundle(
    positional.first,
    password: password,
    outDir: out,
  );
  stdout.writeln(jsonEncode({
    'vault': result.dir,
    'files': result.fileCount,
  }));
}

Future<void> _tui(List<String> args) async {
  final vault = _positional(args);
  if (!Directory(vault).existsSync()) {
    throw ArgumentError('vault tidak ditemukan: $vault');
  }
  await runTui(vault);
}

Future<void> _syncInit(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {});
  final device = opts['device'] ??
      Platform.environment['SIMPUL_DEVICE'] ??
      Platform.localHostname;
  final status = await DeltaSync.initJournal(vault, deviceId: device);
  stdout.writeln(jsonEncode(status.toJson()));
}

Future<void> _syncStatus(List<String> args) async {
  final vault = _positional(args);
  stdout.writeln(jsonEncode((await DeltaSync.status(vault)).toJson()));
}

Future<void> _syncExport(List<String> args) async {
  final vault = _positional(args);
  final opts = _options(args, {'encrypt'});
  final password = opts.containsKey('encrypt') ? _passwordFromEnv() : null;
  if (opts.containsKey('encrypt') && password == null) {
    throw ArgumentError('--encrypt butuh SIMPUL_PASSWORD');
  }
  final result = await DeltaSync.exportDelta(
    vault,
    peerDeviceId: opts['peer'],
    peerJournalFile: opts['peer-journal'],
    password: password,
    outPath: opts['out'],
    crypto: await _vaultCryptoFor(vault),
  );
  stdout.writeln(jsonEncode({
    'delta': result.path,
    'files': result.fileCount,
    'tombstones': result.tombstoneCount,
    'bytes': result.sizeBytes,
    'peer': result.peerDeviceId,
  }));
}

Future<void> _syncImport(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul sync-import <vault> <delta>');
  }
  final opts = _options(args, {});
  const strategies = {
    'keep-both': ConflictStrategy.keepBoth,
    'newest': ConflictStrategy.newest,
    'theirs': ConflictStrategy.theirs,
    'ours': ConflictStrategy.ours,
  };
  final strategyName = opts['strategy'] ?? 'keep-both';
  final strategy = strategies[strategyName] ??
      (throw ArgumentError(
        'strategi tidak dikenal: $strategyName (keep-both|newest|theirs|ours)',
      ));
  final result = await DeltaSync.importDelta(
    positional.first,
    positional[1],
    password: _passwordFromEnv(),
    crypto: await _vaultCryptoFor(positional.first),
    strategy: strategy,
  );
  stdout.writeln(jsonEncode(result.toJson()));
}

Future<void> _vaultStatus(List<String> args) async {
  final vault = _positional(args);
  final status = await VaultModes.status(vault);
  stdout.writeln(jsonEncode({
    'vault': vault,
    'mode': status.mode,
    'locked': status.locked,
    if (status.kdf != null) 'kdf': status.kdf,
    if (status.folders.isNotEmpty) 'folders': status.folders,
    'files': status.indexFiles,
    'encrypted_notes': status.encryptedNotes,
    'total_notes': status.totalNotes,
    'password_available': _passwordFromEnv() != null,
  }));
}

OllamaChat? _chatFromOptions(Map<String, String> opts) {
  if (opts['llm'] != 'true') return null;
  return OllamaChat(
    model: opts['llm-model'] ?? 'llama3.2',
    baseUrl: opts['llm-base-url'] ?? 'http://localhost:11434',
  );
}

Future<void> _ask(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError('pemakaian: simpul ask <vault> "pertanyaan"');
  }
  final vault = positional[0];
  final question = positional[1];
  final opts = _options(args, {'llm'});
  final limit = int.parse(opts['limit'] ?? '8');
  final budget = int.parse(opts['budget'] ?? '2048');
  final dir = opts['out'] ?? p.join(vault, '.simpul');
  final index = await _openIndex(vault, opts['out']);
  try {
    final vectorsFile = File(p.join(dir, 'vectors.json'));
    EmbeddingProvider embedder = HashingEmbedder();
    InMemorySemanticIndex? semantic;
    if (vectorsFile.existsSync()) {
      final ollama = _ollamaFromOptions(opts);
      final expectedModel = ollama?.modelVersion ?? HashingEmbedder().modelVersion;
      final crypto = await _vaultCryptoFor(vault);
      _checkVectorModel(vectorsFile.path, expectedModel, crypto: crypto);
      if (ollama != null) {
        final queryVec = await ollama.embed(question);
        embedder = ReplayEmbedder(
          modelVersion: ollama.modelVersion,
          dimension: ollama.dimension,
          vectors: {question: queryVec},
        );
      }
      semantic = InMemorySemanticIndex(
        embedder,
        filePath: vectorsFile.path,
        crypto: crypto,
      );
    }
    try {
      final answer = await VaultAnswerer(
        index: index,
        semantic: semantic,
        embedder: embedder,
        chat: _chatFromOptions(opts),
        tokenBudget: budget,
      ).ask(question, limit: limit);
      stdout.writeln(jsonEncode(answer.toJson()));
    } finally {
      await semantic?.close();
    }
  } finally {
    await index.close();
  }
}

Future<void> _suggestImprove(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    throw ArgumentError(
      'pemakaian: simpul suggest-improve <vault> <path> --op '
      'ringkasan|tulis-ulang|terjemahan|tugas',
    );
  }
  final vault = positional[0];
  final target = positional[1];
  final opts = _options(args, {});
  final op = SuggestOp.parse(
    opts['op'] ?? (throw ArgumentError('opsi --op wajib diisi')),
  );
  var notePath = target.startsWith('./') ? target.substring(2) : target;
  if (notePath.endsWith('.md')) {
    notePath = notePath.substring(0, notePath.length - 3);
  }
  final index = await _openIndex(vault, opts['out']);
  try {
    final resolved = await index.noteByPath(notePath) != null
        ? notePath
        : await _resolveByBasename(index, notePath);
    if (resolved == null) {
      throw ArgumentError('catatan tidak ditemukan di indeks: $target');
    }
    final file = File(p.join(vault, resolved));
    if (!file.existsSync()) {
      throw StateError('file catatan tidak ada: ${file.path}');
    }
    final content = file.readAsStringSync();
    final chat = OllamaChat(
      model: opts['llm-model'] ?? 'llama3.2',
      baseUrl: opts['llm-base-url'] ?? 'http://localhost:11434',
    );
    final suggestion = await NoteSuggester(chat: chat)
        .suggest(op, content, targetLang: opts['lang']);
    stdout.writeln(jsonEncode({
      'path': resolved,
      'op': op.label,
      if (opts['lang'] != null) 'lang': opts['lang'],
      'suggestion': suggestion,
      'applied': false,
    }));
  } finally {
    await index.close();
  }
}

Future<String?> _resolveByBasename(VaultIndex index, String notePath) async {
  final basename = p.basename(notePath);
  for (final hit in await index.search('path:$basename', limit: 5)) {
    if (hit.path.endsWith('$basename.md') || hit.path == notePath) return hit.path;
  }
  return null;
}
