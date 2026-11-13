import 'dart:math' as math;
import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

/// Deterministic hashing embedder: maps tokens to a fixed-size vector so
/// semantically related texts (shared tokens) get similar vectors.
List<double> hashEmbed(String text, {int dim = 32}) {
  final v = List<double>.filled(dim, 0);
  for (final token in text.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (token.isEmpty) continue;
    v[token.hashCode.abs() % dim] += 1;
  }
  final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
  if (norm == 0) return v;
  return [for (final x in v) x / norm];
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rag_rerank_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('hybrid semantic rerank menaikkan chunk parafrase di atas chunk '
      'yang hanya cocok leksikal', () async {
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${temp.path}/fts1.json'),
      embedder: (text) async => hashEmbed(text),
    );

    // Chunk A is a paraphrase of the query (same concepts, few exact words).
    // Chunk B shares many exact query tokens but is about a different topic.
    await pipeline.ingest(
      'doc',
      'Menyimpan informasi pribadi jangka panjang membutuhkan basis data '
      'vektor dengan pencarian kemiripan.\n\n'
      'vektor basis data pencarian kemiripan memori basis data vektor '
      'pencarian memori vektor basis data pencarian memori',
    );

    final result = await pipeline.retrieve(
      'bagaimana cara menyimpan memori jangka panjang',
      k: 2,
    );
    expect(result.hits, isNotEmpty);
    expect(result.hits.first.chunk.text, contains('jangka panjang'));
  });

  test('tanpa embedder, formula leksikal lama dipertahankan', () async {
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${temp.path}/fts2.json'),
    );
    await pipeline.ingest('doc', 'alpha beta gamma\n\ngamma delta epsilon');
    final result = await pipeline.retrieve('gamma', k: 1);
    expect(result.hits, isNotEmpty);
    expect(result.hits.first.chunk.text, contains('gamma'));
    // Deterministic: same query → same order.
    final again = await pipeline.retrieve('gamma', k: 1);
    expect(again.hits.first.chunk.id, result.hits.first.chunk.id);
  });

  test('ingest meng-cache vektor chunk untuk rerank semantik', () async {
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${temp.path}/fts3.json'),
      embedder: (text) async => hashEmbed(text),
    );
    final chunks = await pipeline.ingest('doc', 'satu dua tiga');
    expect(chunks, hasLength(1));
    final result = await pipeline.retrieve('satu', k: 1);
    expect(result.hits.first.score, greaterThan(0));
  });

  test('remove membersihkan cache vektor dan index durabel', () async {
    final pipeline = RagPipeline(
      dense: BruteForceVectorIndex(),
      lexical: FtsIndex('${temp.path}/fts4.json'),
      embedder: (text) async => hashEmbed(text),
    );
    await pipeline.ingest('doc', 'isi dokumen uji');
    await pipeline.remove('doc');
    expect(pipeline.chunkCount, 0);
    final result = await pipeline.retrieve('isi dokumen', k: 3);
    expect(result.hits, isEmpty);
  });
}
