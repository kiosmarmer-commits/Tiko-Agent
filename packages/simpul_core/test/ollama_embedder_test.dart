import 'dart:convert';
import 'dart:typed_data';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

Map<String, Object?> _okResponse(List<Float32List> vectors) => {
      'embeddings': [
        for (final v in vectors) v.toList(),
      ],
    };

void main() {
  test('embed mengembalikan vektor L2-normalized dari respon Ollama', () async {
    final requests = <Map<String, Object?>>[];
    final embedder = OllamaEmbedder(
      dimension: 4,
      fetch: (url, body) async {
        requests.add(body);
        return _okResponse([
          Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        ]);
      },
    );

    final vector = await embedder.embed('teks uji');

    expect(vector, hasLength(4));
    var norm = 0.0;
    for (final value in vector) {
      norm += value * value;
    }
    expect(norm, closeTo(1.0, 1e-6));
    expect(requests.single['model'], 'nomic-embed-text');
    expect(requests.single['input'], ['teks uji']);
    expect(embedder.modelVersion, 'ollama:nomic-embed-text');
    expect(embedder.dimension, 4);
  });

  test('embedBatch mengirim satu request dan menjaga urutan', () async {
    var callCount = 0;
    final embedder = OllamaEmbedder(
      dimension: 3,
      fetch: (url, body) async {
        callCount++;
        final input = body['input'] as List<Object?>;
        return _okResponse([
          for (var i = 0; i < input.length; i++)
            Float32List.fromList([1.0 + i, 0.0, 0.0]),
        ]);
      },
    );

    final vectors = await embedder.embedBatch(['a', 'b', 'c']);

    expect(callCount, 1);
    expect(vectors, hasLength(3));
    expect(vectors[0][0], closeTo(1.0, 1e-6));
    expect(vectors[2][0], closeTo(1.0, 1e-6));
    for (final v in vectors) {
      var norm = 0.0;
      for (final value in v) {
        norm += value * value;
      }
      expect(norm, closeTo(1.0, 1e-6));
    }
  });

  test('embedBatch kosong tidak memanggil transport', () async {
    var called = false;
    final embedder = OllamaEmbedder(
      fetch: (url, body) async {
        called = true;
        return _okResponse([]);
      },
    );

    expect(await embedder.embedBatch([]), isEmpty);
    expect(called, isFalse);
  });

  test('dimensi vektor yang tidak cocok → StateError (fail-closed)', () async {
    final embedder = OllamaEmbedder(
      dimension: 4,
      fetch: (url, body) async => _okResponse([
            Float32List.fromList([1.0, 0.0]),
          ]),
    );

    await expectLater(embedder.embed('teks'), throwsStateError);
  });

  test('vektor norm 0 → StateError (fail-closed)', () async {
    final embedder = OllamaEmbedder(
      dimension: 4,
      fetch: (url, body) async => _okResponse([
            Float32List(4),
          ]),
    );

    await expectLater(embedder.embed('teks'), throwsStateError);
  });

  test('jumlah vektor tidak cocok dengan input → StateError', () async {
    final embedder = OllamaEmbedder(
      dimension: 4,
      fetch: (url, body) async => _okResponse([
            Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          ]),
    );

    await expectLater(
      embedder.embedBatch(['a', 'b']),
      throwsStateError,
    );
  });

  test('HTTP non-200 → StateError dengan kode status', () async {
    final embedder = OllamaEmbedder(
      fetch: (url, body) async => throw StateError('Ollama HTTP 500'),
    );

    await expectLater(embedder.embed('teks'), throwsStateError);
  });

  test('timeout transport → StateError', () async {
    final embedder = OllamaEmbedder(
      timeout: const Duration(milliseconds: 20),
      fetch: (url, body) => Future.delayed(
        const Duration(seconds: 5),
        () => _okResponse([]),
      ),
    );

    await expectLater(embedder.embed('teks'), throwsStateError);
  });

  test('respon JSON non-map → StateError', () async {
    final embedder = OllamaEmbedder(
      fetch: (url, body) async => jsonDecode('[1,2,3]') as Object?,
    );

    await expectLater(embedder.embed('teks'), throwsStateError);
  });
}
