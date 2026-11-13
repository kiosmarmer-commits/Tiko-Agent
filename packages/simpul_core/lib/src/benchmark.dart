import 'package:path/path.dart' as p;

import 'graph_csr.dart';
import 'vault_index.dart';
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

    await index.close();
    return report;
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
