import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<Directory> _vault() async {
  final temp = await Directory.systemTemp.createTemp('graph_rag_vault_');
  await File(p.join(temp.path, 'jaringan.md')).writeAsString('''
# Jaringan Neural
Jaringan neural konvolusional mengenali citra medis paru-paru.
Akurasi model CNN meningkat dengan augmentasi data.
Lihat [[pelatihan-model]].
''');
  await File(p.join(temp.path, 'pelatihan-model.md')).writeAsString('''
# Pelatihan Model
Pelatihan transformer membutuhkan GPU besar dan data besar.
Fine-tuning model kecil lebih murah dengan attention sparse.
Terkait: [[jaringan]].
''');
  await File(p.join(temp.path, 'resep-masak.md')).writeAsString('''
# Resep Rendang
Rendang dimasak lama dengan santan dan rempah.
Bumbu halus penting untuk cita rasa rendang.
''');
  return temp;
}

void main() {
  test('GRAPHRAG-2: tool graph_query — build otomatis + query + kosong',
      () async {
    final temp = await _vault();
    addTearDown(() => temp.delete(recursive: true));
    final events = <String>[];
    final tool = GraphRagQueryTool(
      vaultDir: temp.path,
      maxHops: 2,
      maxNotes: 500,
      onEvent: (type, _) => events.add(type),
    );
    final ctx = ToolContext(
      session: Session(id: 's-graph', channel: 'test', userKey: 't'),
      workspacePath: temp.path,
    );

    final noQuery = await tool.run({}, ctx);
    expect(noQuery.isError, isTrue);

    final ok = await tool.run({'query': 'pelatihan model GPU'}, ctx);
    expect(ok.isError, isFalse, reason: ok.content);
    expect(ok.content, contains('"sources"'));
    expect(ok.content, contains('pelatihan-model.md'));
    expect(events, contains('graph_rag.indexed'));
    expect(events, contains('graph_rag.query'));

    final irrelevant = await tool.run(
      {'query': 'xyzzy filosofi kambing qwerty unik'},
      ctx,
    );
    expect(irrelevant.isError, isFalse);
    expect(irrelevant.content, contains('"empty": true'));
  });

  test('GRAPHRAG-3: config parser — fail-open, default off', () {
    final (cfg, issues) = TikoConfig.parse('''
graph_rag:
  enabled: true
  vault_dir: /tmp/vault
  max_hops: 3
  max_notes: 100
''');
    expect(issues.where((i) => i.fatal), isEmpty);
    expect(cfg.graphRag.enabled, isTrue);
    expect(cfg.graphRag.vaultDir, '/tmp/vault');
    expect(cfg.graphRag.maxHops, 3);
    expect(cfg.graphRag.maxNotes, 100);

    final (badCfg, _) = TikoConfig.parse('''
graph_rag:
  enabled: oops
  max_hops: 99
''');
    expect(badCfg.graphRag.enabled, isFalse, reason: 'default off');
    expect(badCfg.graphRag.maxHops, 2);

    final (defCfg, _) = TikoConfig.parse('');
    expect(defCfg.graphRag.enabled, isFalse);
    expect(defCfg.graphRag.vaultDir, isEmpty);
  });

  test('GRAPHRAG-4: runtime wiring — off tanpa tool, on dengan vault → tool',
      () async {
    final temp = await _vault();
    addTearDown(() => temp.delete(recursive: true));
    final configDir = await Directory(p.join(temp.path, 'cfg')).create();
    final configPath = p.join(configDir.path, 'agent.yaml');
    final template = '''
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
graph_rag:
  enabled: ENABLED
  vault_dir: VAULT
''';
    await File(configPath).writeAsString(
      template
          .replaceAll('ENABLED', 'false')
          .replaceAll('VAULT', temp.path),
    );
    final offRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(offRt.close);
    expect(offRt.registry.get('graph_query'), isNull);

    await File(configPath).writeAsString(
      template
          .replaceAll('ENABLED', 'true')
          .replaceAll('VAULT', temp.path),
    );
    final onRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(onRt.close);
    expect(onRt.registry.get('graph_query'), isNotNull);
  });
}
