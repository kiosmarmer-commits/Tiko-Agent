import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// GUI-P1-12: Memory Explorer — kurasi MEMORY.md/USER.md (read/replace
/// beranggaran), entri berlapis (list/add/delete + retrieval), sumber RAG.
void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_memexp_');
    final config = File(p.join(temp.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${p.join(temp.path, 'workspace')}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
mcp:
  servers: []
''');
    rt = await TikoRuntime.create(configPath: config.path, safe: false);
  });

  tearDown(() async {
    await rt.close();
    await temp.delete(recursive: true);
  });

  test('kurasi: get kosong, set + persist ke MEMORY.md, budget ditolak', () async {
    final empty = rt.memoryCuratedGet();
    expect(empty['used'], 0);
    expect((empty['memory'] as Map)['text'], '');

    final ok = await rt.memoryCuratedSet(
      file: 'memory',
      text: 'pemilik: Andi\nbahasa: Indonesia',
    );
    expect(ok['ok'], isTrue);
    expect(ok['used'] as int, greaterThan(0));

    final after = rt.memoryCuratedGet();
    expect(((after['memory'] as Map)['text'] as String), contains('Andi'));
    expect(after['budget'], (empty['budget'] as int));

    final persisted =
        File(p.join(temp.path, 'data', 'memories', 'MEMORY.md'));
    expect(persisted.existsSync(), isTrue);
    expect(persisted.readAsStringSync(), contains('Andi'));

    await expectLater(
      rt.memoryCuratedSet(file: 'user', text: 'x' * 5000),
      throwsA(isA<ArgumentError>()),
    );

    await expectLater(
      rt.memoryCuratedSet(file: 'kanal', text: 'x'),
      throwsA(isA<ArgumentError>()),
    );

    final restored = await rt.memoryCuratedSet(file: 'memory', text: '');
    expect(restored['used'], 0);
  });

  test('lapisan: add → list → retrieval query → delete → 404', () async {
    final added = await rt.memoryLayerAdd(
      layer: 'semantic',
      text: 'deploy memakai script release.sh di folder deploy',
      importance: 0.8,
      tags: ['deploy'],
      ownerKey: 'admin',
    );
    expect(added['layer'], 'semantic');
    expect(added['importance'], 0.8);
    final id = added['id'] as String;

    rt.memoryLayerAdd(layer: 'episodic', text: 'catatan sesi pagi');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final listing = rt.memoryLayersGet();
    expect(listing['total'], 2);
    expect((listing['entries'] as List), hasLength(2));
    expect((listing['stats'] as Map)['semantic'], containsPair('count', 1));

    final searched = rt.memoryLayersGet(query: 'deploy script release');
    expect((searched['entries'] as List), isNotEmpty);
    expect(((searched['entries'] as List).first as Map)['id'], id);

    final persisted = File(p.join(temp.path, 'data', 'layered_memory.json'));
    expect(persisted.existsSync(), isTrue);

    expect(await rt.memoryLayerDelete(id), isTrue);
    expect(rt.memoryLayersGet()['total'], 1);

    await expectLater(
      rt.memoryLayerDelete('m-tak-ada'),
      throwsA(isA<StateError>()),
    );

    expect(
      () => rt.memoryLayerAdd(layer: 'bos', text: 'x'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => rt.memoryLayerAdd(layer: 'semantic', text: '   '),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('rag: sumber kosong, ingest → dikelompokkan per dokumen', () async {
    final empty = rt.memoryRagSources();
    expect(empty['chunk_count'], 0);
    expect((empty['docs'] as List), isEmpty);

    await rt.ragPipeline.ingest(
      'doc-readme',
      'Tiko adalah agent runtime lokal. ',
      meta: {'source': 'test'},
    );
    await rt.ragPipeline.ingest(
      'doc-alg',
      'Algoritma loop agent menjalankan tool berulang. ' * 3,
    );

    final sources = rt.memoryRagSources();
    expect(sources['chunk_count'] as int, greaterThan(0));
    final docs = sources['docs'] as List;
    expect(docs.length, 2);
    expect(docs.map((d) => d['doc_id']), containsAll(['doc-readme', 'doc-alg']));
    final readme = docs.firstWhere((d) => d['doc_id'] == 'doc-readme');
    expect(readme['chunks'], 1);
    expect((readme['preview'] as String), isNotEmpty);
    expect((sources['truncated'] as bool), isFalse);
  });
}
