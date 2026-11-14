import 'package:path/path.dart' as p;

import 'embedding.dart';
import 'graph_csr.dart';
import 'hybrid_search.dart';
import 'semantic_index.dart';
import 'vault_index.dart';
import 'vault_index_sqlite_stub.dart'
    if (dart.library.ffi) 'vault_index_sqlite.dart';
import 'vault_scanner.dart';

/// Benchmark runner for BM-02..BM-05 (PRD `03-performa-skala.md` §5).
///
/// All numbers are measurements, not promises (ADR-15): the report is JSON so
/// results can be tracked across runs.
class BenchmarkRunner {
  BenchmarkRunner({this.indexFactory});

  /// Injectable so tests and hosts can force the JSON backend.
  final VaultIndex Function(String path)? indexFactory;

  Future<Map<String, Object?>> run(
    String vaultDir, {
    String workDir = '.simpul_bench',
    int searchIterations = 50,
  }) async {
    final index = indexFactory?.call(p.join(workDir, 'index.json')) ??
        SqliteVaultIndex.tryOpen(p.join(workDir, 'index.db')) ??
        JsonVaultIndex(p.join(workDir, 'index.json'));

    final report = <String, Object?>{
      'backend': index is SqliteVaultIndex ? 'sqlite' : 'json',
      'vault_dir': vaultDir,
    };

    final scanWatch = Stopwatch()..start();
    final notes = await VaultScanner.scan(vaultDir);
    scanWatch.stop();
    final noteCount = notes.length;
    report['bm02_scan_ms'] = scanWatch.elapsedMilliseconds;
    report['bm02_notes'] = noteCount;
    report['bm02_notes_per_sec'] = scanWatch.elapsedMilliseconds == 0
        ? null
        : (noteCount * 1000 / scanWatch.elapsedMilliseconds).round();

    final indexWatch = Stopwatch()..start();
    await index.replaceAll([for (final n in notes) n.toIndexed()]);
    indexWatch.stop();
    report['bm02_index_ms'] = indexWatch.elapsedMilliseconds;
    report['bm02_index_notes_per_sec'] = indexWatch.elapsedMilliseconds == 0
        ? null
        : (noteCount * 1000 / indexWatch.elapsedMilliseconds).round();

    final terms = _frequentTerms(notes);
    final latencies = <int>[];
    var totalHits = 0;
    for (var i = 0; i < searchIterations; i++) {
      final query = terms[i % terms.length];
      final watch = Stopwatch()..start();
      final hits = await index.search(query, limit: 20);
      latencies.add(watch.elapsedMicroseconds);
      totalHits += hits.length;
    }
    latencies.sort();
    report['bm03_iterations'] = searchIterations;
    report['bm03_p50_us'] = _percentile(latencies, 50);
    report['bm03_p95_us'] = _percentile(latencies, 95);
    report['bm03_avg_hits'] = totalHits / searchIterations;

    if (notes.isNotEmpty) {
      final target = notes.first.parsed;
      final watch = Stopwatch()..start();
      final links = await index.backlinks(target.path);
      watch.stop();
      report['bm05_backlink_us'] = watch.elapsedMicroseconds;
      report['bm05_backlink_count'] = links.length;
    }

    final graphWatch = Stopwatch()..start();
    final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
    graphWatch.stop();
    report['bm06_csr_build_ms'] = graphWatch.elapsedMilliseconds;
    report['bm06_nodes'] = graph.nodeCount;
    report['bm06_edges'] = graph.edgeCount;
    report['bm06_orphans'] = graph.orphanNodes().length;

    await _runIncrementalBench(index, notes, report);
    await _runVectorBench(notes, report);

    await index.close();
    return report;
  }

  /// BM-04 (NFR-08): upsert a changed subset and measure time-to-indexed.
  Future<void> _runIncrementalBench(
    VaultIndex index,
    List<ScannedNote> notes,
    Map<String, Object?> report,
  ) async {
    if (notes.isEmpty) return;
    final batch = notes.take(notes.length < 100 ? notes.length : 100).toList();
    final changed = [
      for (final n in batch)
        IndexedNote(
          path: n.path,
          title: n.parsed.title,
          mtimeNs: n.mtimeNs + 1,
          sizeBytes: n.sizeBytes + 32,
          contentHash: 'bm04-${n.contentHash}',
          wordCount: n.parsed.wordCount,
          props: n.parsed.props,
          tags: n.parsed.tags,
          aliases: n.parsed.aliases,
          links: n.parsed.links,
          chunks: n.parsed.chunks,
        ),
    ];
    final watch = Stopwatch()..start();
    await index.upsert(changed);
    watch.stop();
    report['bm04_upsert_notes'] = changed.length;
    report['bm04_upsert_ms'] = watch.elapsedMilliseconds;
  }

  /// BM-07 (AI-30/31, ADR-06): int8 brute-force vector search latency and
  /// recall@10 versus full-precision exact ranking.
  Future<void> _runVectorBench(
    List<ScannedNote> notes,
    Map<String, Object?> report,
  ) async {
    const maxChunks = 2000;
    final embedder = HashingEmbedder();
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
        if (chunks.length >= maxChunks) break;
      }
      if (chunks.length >= maxChunks) break;
    }
    if (chunks.length < 2) return;

    final embedWatch = Stopwatch()..start();
    final semantic = InMemorySemanticIndex(embedder);
    await semantic.replaceAll(chunks);
    embedWatch.stop();
    report['bm07_embed_chunks'] = chunks.length;
    report['bm07_embed_ms'] = embedWatch.elapsedMilliseconds;

    final exact = [
      for (final chunk in chunks) embedder.embed(chunk.text),
    ];
    final queries = [
      for (final term in _frequentTerms(notes).take(5)) embedder.embed(term),
      if (chunks.isNotEmpty) embedder.embed(chunks.first.text),
    ];

    final chunkIndexByKey = <(String, int), int>{
      for (var i = 0; i < chunks.length; i++) (chunks[i].notePath, chunks[i].ord): i,
    };
    final latencies = <int>[];
    var recallSum = 0.0;
    for (final query in queries) {
      final watch = Stopwatch()..start();
      final hits = await semantic.search(query, limit: 10);
      latencies.add(watch.elapsedMicroseconds);
      final exactTop = exactTopK(query, exact, 10).toSet();
      final quantTop = [
        for (final h in hits) chunkIndexByKey[(h.notePath, h.ord)],
      ].whereType<int>().toSet();
      recallSum += quantTop.intersection(exactTop).length / exactTop.length;
    }
    latencies.sort();
    report['bm07_search_p50_us'] = latencies[latencies.length ~/ 2];
    report['bm07_search_p95_us'] = latencies[(latencies.length - 1) * 95 ~/ 100];
    report['bm07_recall_at10'] = recallSum / queries.length;
  }

  List<String> _frequentTerms(List<ScannedNote> notes) {
    final counts = <String, int>{};
    for (final note in notes) {
      for (final tag in note.parsed.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) return ['catatan'];
    return [
      for (final e in sorted.take(5)) e.key,
    ];
  }

  int _percentile(List<int> sortedUs, int percentile) {
    if (sortedUs.isEmpty) return 0;
    final index = ((sortedUs.length - 1) * percentile / 100).floor();
    return sortedUs[index];
  }
}
