import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  test('fingerprint stabil untuk graf sama dan berubah saat topologi berubah', () {
    final a = GraphCsr.fromEdges(3, [(0, 1), (1, 2)]);
    final b = GraphCsr.fromEdges(3, [(0, 1), (1, 2)]);
    expect(graphFingerprint(a), graphFingerprint(b));

    final c = GraphCsr.fromEdges(3, [(0, 1), (0, 2)]);
    expect(graphFingerprint(a), isNot(graphFingerprint(c)));
  });

  test('layoutCacheVersion memasukkan algoritma, iterasi, dan fingerprint', () {
    final graph = GraphCsr.fromEdges(2, [(0, 1)]);
    final base = layoutCacheVersion(graph, iterations: 300);
    expect(base, startsWith('barnes-hut-v1:300:'));
    expect(
      layoutCacheVersion(graph, iterations: 300, multiLevel: true),
      startsWith('multi-level-v1:300:'),
    );
    expect(
      layoutCacheVersion(graph, iterations: 100),
      isNot(layoutCacheVersion(graph, iterations: 300)),
    );
    expect(layoutCacheKind(), 'layout');
    expect(layoutCacheKind(multiLevel: true), 'layout-multi-level');
  });

  test('applyWarmStart mengisi posisi valid dan mengabaikan payload salah', () {
    final graph = GraphCsr.fromEdges(2, [(0, 1)]);
    applyWarmStart(graph, {
      'x': [1.5, 2.5],
      'y': [3.0, 4.0],
    });
    expect(graph.positionsX[0], 1.5);
    expect(graph.positionsY[1], 4.0);

    final cold = GraphCsr.fromEdges(2, [(0, 1)]);
    applyWarmStart(cold, {'x': [1.0]});
    applyWarmStart(cold, {'x': [1, 2], 'y': ['bukan', 'angka']});
    applyWarmStart(cold, {'x': [1, 2, 3], 'y': [1, 2, 3]});
    expect(cold.positionsX[0], 0.0);
  });

  test('openVaultCacheStore hanya membuka index yang ada (fail-closed)', () async {
    final tmp = await Directory.systemTemp.createTemp('simpul-layout-cache');
    try {
      expect(openVaultCacheStore(tmp.path), isNull);

      final index = JsonVaultIndex('${tmp.path}/.simpul/index.json');
      await index.replaceAll(const []);
      await index.close();
      final store = openVaultCacheStore(tmp.path);
      expect(store, isNotNull);
      await (store as VaultIndex).close();
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('warm start lintas CLI: simpan lalu muat kembali dengan versi sama', () async {
    final tmp = await Directory.systemTemp.createTemp('simpul-layout-cache');
    try {
      final graph = GraphCsr.fromEdges(4, [(0, 1), (1, 2), (2, 3)]);
      final version = layoutCacheVersion(graph, iterations: 50);
      final kind = layoutCacheKind();

      final writer = JsonVaultIndex('${tmp.path}/.simpul/index.json');
      await writer.replaceAll(const []);
      await writer.saveGraphCache(kind: kind, version: version, payload: {
        'x': [1, 2, 3, 4],
        'y': [5, 6, 7, 8],
      });
      await writer.close();

      final reader = openVaultCacheStore(tmp.path);
      final cached = await reader!.loadGraphCache(kind: kind, version: version);
      await (reader as VaultIndex).close();
      expect(cached, isNotNull);
      applyWarmStart(graph, cached!);
      expect(graph.positionsX[3], 4.0);
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
