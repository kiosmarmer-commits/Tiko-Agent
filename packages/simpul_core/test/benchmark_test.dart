import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  test('benchmark report has the expected shape', () async {
    final tmp = await Directory.systemTemp.createTemp('simpul-bench-test');
    addTearDown(() => tmp.delete(recursive: true));
    final generator = VaultGenerator(seed: 11);
    final manifest = await generator.generate('${tmp.path}/vault', 25);
    expect(manifest.noteCount, 25);

    final report = await BenchmarkRunner(
      indexFactory: (path) => JsonVaultIndex(path),
    ).run('${tmp.path}/vault/catatan_vault', workDir: '${tmp.path}/.bench', searchIterations: 10);

    expect(report['backend'], 'json');
    expect(report['bm02_notes'], 25);
    expect(report['bm02_scan_ms'], isA<int>());
    expect(report['bm02_index_ms'], isA<int>());
    expect(report['bm03_iterations'], 10);
    expect(report['bm03_p50_us'], isA<int>());
    expect(report['bm03_p95_us'], isA<int>());
    expect(report['bm03_avg_hits'], isA<double>());
    expect(report['bm05_backlink_count'], isA<int>());
    expect(report['bm06_nodes'], 25);
    expect(report['bm06_edges'], greaterThan(0));
    expect(report['bm06_orphans'], isA<int>());
  });
}
