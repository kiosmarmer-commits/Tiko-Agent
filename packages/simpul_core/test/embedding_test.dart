import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  final embedder = HashingEmbedder(dim: 128);

  test('model version and dimension are exposed', () {
    expect(embedder.modelVersion, 'hashing-v1');
    expect(embedder.dimension, 128);
  });

  test('embeddings are deterministic and L2-normalized', () {
    final a = embedder.embed('kucing duduk di atas meja');
    final b = embedder.embed('kucing duduk di atas meja');
    expect(a, b);

    var norm = 0.0;
    for (final v in a) {
      norm += v * v;
    }
    expect(norm, closeTo(1.0, 1e-5));
  });

  test('similar text scores higher than unrelated text', () {
    final query = embedder.embed('jaringan saraf tiruan untuk pengenalan gambar');
    final related = embedder.embed(
      'model jaringan saraf tiruan belajar dari data gambar berlabel',
    );
    final unrelated = embedder.embed('resep masakan rendang padang');

    final q = QuantizedVector.encode(query, 'hashing-v1');
    final r = QuantizedVector.encode(related, 'hashing-v1');
    final u = QuantizedVector.encode(unrelated, 'hashing-v1');

    expect(q.cosine(r), greaterThan(q.cosine(u)));
    expect(q.cosine(r), greaterThan(0.1));
  });

  test('multilingual text produces non-zero embeddings', () {
    final id = embedder.embed('pencarian semantik di catatan lokal');
    final en = embedder.embed('semantic search across local notes');
    var nonZero = 0;
    for (var i = 0; i < id.length; i++) {
      if (id[i] != 0 || en[i] != 0) nonZero++;
    }
    expect(nonZero, greaterThan(10));
  });

  test('int8 quantization keeps cosine close to full precision', () {
    final a = embedder.embed('indeks vault markdown dengan sqlite');
    final b = embedder.embed('vault markdown diindeks ke sqlite fts5');
    final qa = QuantizedVector.encode(a, 'hashing-v1');
    final qb = QuantizedVector.encode(b, 'hashing-v1');

    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    expect(qa.cosine(qb), closeTo(dot, 0.05));
    expect(qa.data.every((v) => v >= -127 && v <= 127), isTrue);
  });

  test('empty text yields a zero vector', () {
    final v = embedder.embed('   ');
    expect(v, Float32List(128));
  });
}
