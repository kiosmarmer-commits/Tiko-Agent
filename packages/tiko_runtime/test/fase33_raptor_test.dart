import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

List<({String id, String text})> _corpus() => [
      (
        id: 'doc-a#0',
        text:
            'Jaringan neural konvolusional mengenali citra medis. Model CNN '
            'dilatih dengan ribuan citra paru-paru. Akurasi CNN meningkat '
            'dengan augmentasi data citra medis.',
      ),
      (
        id: 'doc-a#1',
        text:
            'Transformers menggantikan RNN untuk pemrosesan bahasa alami. '
            'Model transformer memakai mekanisme attention multi-head. '
            'Pelatihan transformer membutuhkan GPU besar.',
      ),
      (
        id: 'doc-b#0',
        text:
            'Deteksi penyakit paru menggunakan CNN memperoleh sensitivitas '
            'tinggi. Citra paru-paru dievaluasi radiolog dan model CNN. '
            'Augmentasi citra menaikkan recall deteksi paru.',
      ),
      (
        id: 'doc-b#1',
        text:
            'Fine-tuning transformer kecil lebih murah. Attention sparse '
            'mengurangi biaya pelatihan transformer. Model bahasa kecil '
            'tetap kompetitif pada benchmark tertentu.',
      ),
    ];

void main() {
  group('RaptorTree', () {
    test('RAPTOR-1: build deterministik + hierarki terbentuk', () {
      final a = RaptorTree()..build(_corpus());
      final b = RaptorTree()..build(_corpus());
      expect(a.built, isTrue);
      expect(a.nodeCount, greaterThan(4), reason: 'daun + ringkasan');
      expect(a.toJson(), b.toJson(), reason: 'build ulang identik');

      final levels = <int, int>{};
      for (final n in a.nodes) {
        levels[n.level] = (levels[n.level] ?? 0) + 1;
      }
      expect(levels.containsKey(1), isTrue, reason: 'ada level ringkasan');
      final summaries = a.nodes.where((n) => n.level > 0).toList();
      expect(
        summaries.every((n) => n.childIds.isNotEmpty),
        isTrue,
      );
      expect(
        summaries.every((n) => n.sourceChunkIds.isNotEmpty),
        isTrue,
        reason: 'citation chain ke chunk sumber',
      );
    });

    test('RAPTOR-2: query global men-match ringkasan level atas', () {
      final tree = RaptorTree()..build(_corpus());
      final result = tree.query('tema utama pelatihan model citra medis');
      expect(result.matchedNodes, isNotEmpty);
      expect(result.sourceChunkIds, isNotEmpty);
      expect(
        result.matchedNodes.first.$1.level,
        greaterThanOrEqualTo(0),
      );
      // Query tanpa term relevan → hasil kosong, tanpa raise.
      final empty = tree.query('xyzzy qwerty filosofi kambing unik');
      expect(empty.matchedNodes.any((m) => m.$2 > 0.5), isFalse);
    });

    test('RAPTOR-3: persist round-trip save/load', () {
      final temp = Directory.systemTemp.createTempSync('raptor_rt_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = p.join(temp.path, 'raptor', 'tree.json');
      final tree = RaptorTree()..build(_corpus());
      expect(tree.save(path), isTrue);
      final loaded = RaptorTree.load(path);
      expect(loaded, isNotNull);
      expect(loaded!.toJson(), tree.toJson());
      expect(RaptorTree.load(p.join(temp.path, 'absen.json')), isNull);
    });

    test('RAPTOR-4: korpus kosong → pohon kosong tanpa raise', () {
      final tree = RaptorTree();
      expect(tree.build([]), 0);
      expect(tree.built, isFalse);
      expect(tree.query('apa pun').matchedNodes, isEmpty);
    });
  });

  test('RAPTOR-5: tool raptor — build/query/status end-to-end', () async {
    final temp = await Directory.systemTemp.createTemp('raptor_tool_');
    addTearDown(() => temp.delete(recursive: true));
    final events = <String>[];
    final tool = RaptorTool(
      chunksProvider: _corpus,
      treePath: p.join(temp.path, 'raptor', 'tree.json'),
      onEvent: (type, _) => events.add(type),
    );
    final ctx = ToolContext(
      session: Session(id: 's-raptor', channel: 'test', userKey: 't'),
      workspacePath: temp.path,
    );

    final before = await tool.run({'action': 'status'}, ctx);
    expect(before.content, contains('"built": false'));

    final built = await tool.run({'action': 'build'}, ctx);
    expect(built.isError, isFalse);
    expect(built.content, contains('"nodes"'));
    expect(events, contains('raptor.built'));

    final queried = await tool.run(
      {'action': 'query', 'query': 'pelatihan model citra medis'},
      ctx,
    );
    expect(queried.isError, isFalse);
    expect(queried.content, contains('source_chunk_ids'));
    expect(queried.content, contains('doc-a#0'));
    expect(events, contains('raptor.query'));

    final noQuery = await tool.run({'action': 'query'}, ctx);
    expect(noQuery.isError, isTrue);

    final badAction = await tool.run({'action': 'hantu'}, ctx);
    expect(badAction.isError, isTrue);
  });

  test('RAPTOR-6: runtime wiring — tool raptor terdaftar', () async {
    final temp = await Directory.systemTemp.createTemp('raptor_rt_wiring_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'config')).create();
    final configPath = p.join(configDir.path, 'agent.yaml');
    await File(configPath).writeAsString('''
profile: default
workspace: ${temp.path}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
mcp:
  servers: []
''');
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.registry.get('raptor'), isNotNull);
  });
}
