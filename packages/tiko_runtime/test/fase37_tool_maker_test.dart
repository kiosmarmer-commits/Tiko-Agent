import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _validDef = '''
```json
{"name":"made_word_count","description":"Menghitung kata dari input teks",
 "command":["cat"],
 "tests":[
   {"input":{"text":"satu dua tiga"},"expect_contains":"3"},
   {"input":{"text":"satu"},"expect_contains":"1"}
 ]}
```
''';

ToolMakerPipeline _pipeline({
  required ToolForge forge,
  required List<Tool> registered,
  required String? Function(String prompt) reply,
  List<String>? existingNames,
}) {
  return ToolMakerPipeline(
    forge: forge,
    makerTurn: (prompt) async => reply(prompt),
    hasTool: (name) =>
        existingNames?.contains(name) ??
        registered.any((t) => t.spec.name == name),
    registerTool: registered.add,
  );
}

Future<ProcessResult> _ok(List<String> parts) async =>
    ProcessResult(0, 0, 'ok', '');

void main() {
  test('TOOLMAKER-1: alur penuh — maker → contract tests → instalasi',
      () async {
    final registered = <Tool>[];
    final forge = ToolForge(commandRunner: (parts) async {
      final json = parts.last;
      expect(parts.first, 'cat');
      final n = (jsonDecode(json) as Map)['text'].toString().split(' ').length;
      return ProcessResult(0, 0, '$n', '');
    });
    final prompts = <String>[];
    final pipeline = _pipeline(
      forge: forge,
      registered: registered,
      reply: (prompt) {
        prompts.add(prompt);
        expect(prompt, contains('TOOL MAKER'));
        expect(prompt, contains('made_'));
        return _validDef;
      },
    );
    final report = await pipeline.make(task: 'hitung kata teks');
    expect(report.ok, isTrue, reason: report.toJson().toString());
    expect(report.toolName, 'made_word_count');
    expect(report.testsRun, 2);
    expect(report.reason, 'installed');
    expect(forge.isInstalled('made_word_count'), isTrue);
    expect(registered.map((t) => t.spec.name), contains('made_word_count'));
    expect(prompts, hasLength(1));
  });

  test('TOOLMAKER-2: parse def — namespace made_ + batas keras', () async {
    final forge = ToolForge(commandRunner: _ok);
    final pipeline = _pipeline(
      forge: forge,
      registered: [],
      reply: (_) => _validDef,
    );
    expect(pipeline.parseMakerDef(_validDef), isNotNull);
    expect(pipeline.parseMakerDef('{"name":"tool_lain","description":"x",'
        '"command":["cat"],"tests":[{"input":{}}]}'), isNull,
        reason: 'tanpa prefix made_');
    expect(pipeline.parseMakerDef('{"name":"made_ok","description":"x",'
        '"command":["cat"],"tests":[]}'), isNull, reason: 'tests kosong');
    expect(pipeline.parseMakerDef('bukan json'), isNull);
    expect(pipeline.parseMakerDef('{"name":"made_ok","description":"",'
        '"command":["cat"],"tests":[{"input":{}}]}'), isNull,
        reason: 'description kosong');
    expect(pipeline.parseMakerDef('{"name":"made_ok","description":"x",'
        '"command":["a","b","c","d","e","f","g","h","i","j","k","l","m"],'
        '"tests":[{"input":{}}]}'), isNull,
        reason: 'command > maxCommandParts');
  });

  test('TOOLMAKER-3: contract tests gagal → tidak terpasang (fail-closed)',
      () async {
    final registered = <Tool>[];
    final forge = ToolForge(commandRunner: (parts) async {
      return ProcessResult(0, 1, '', 'boom');
    });
    final pipeline = _pipeline(
      forge: forge,
      registered: registered,
      reply: (_) => _validDef,
    );
    final report = await pipeline.make(task: 'hitung kata');
    expect(report.ok, isFalse);
    expect(report.reason, 'contract_tests');
    expect(report.testsRun, 2);
    expect(forge.isInstalled('made_word_count'), isFalse);
    expect(registered, isEmpty);
  });

  test('TOOLMAKER-4: nama bentrok → ditolak sebelum tests', () async {
    final registered = <Tool>[];
    final forge = ToolForge(commandRunner: _ok);
    final pipeline = _pipeline(
      forge: forge,
      registered: registered,
      existingNames: ['made_word_count'],
      reply: (_) => _validDef,
    );
    final report = await pipeline.make(task: 'hitung kata');
    expect(report.ok, isFalse);
    expect(report.reason, 'validate');
    expect(report.error, contains('sudah terpakai'));
    expect(registered, isEmpty);
  });

  test('TOOLMAKER-5: maker gagal (garbage / null / throw) → jujur, '
      'never-raises', () async {
    for (final scenario in [
      ('garbage', (_) => 'saya tidak mengerti'),
      ('null', (_) => null),
      ('throw', (_) => throw StateError('llm mati')),
    ]) {
      final registered = <Tool>[];
      final forge = ToolForge(commandRunner: _ok);
      final pipeline = _pipeline(
        forge: forge,
        registered: registered,
        reply: scenario.$2,
      );
      final report = await pipeline.make(task: 'task apa pun');
      expect(report.ok, isFalse, reason: scenario.$1);
      expect(registered, isEmpty, reason: scenario.$1);
      expect(
        report.reason,
        scenario.$1 == 'garbage' ? 'validate' : 'maker',
      );
    }
  });

  test('TOOLMAKER-6: config parser — fail-open, default off', () {
    final (cfg, issues) = TikoConfig.parse('''
tool_maker:
  enabled: true
  max_tests: 4
  max_command_parts: 6
''');
    expect(issues.where((i) => i.fatal), isEmpty);
    expect(cfg.toolMaker.enabled, isTrue);
    expect(cfg.toolMaker.maxTests, 4);
    expect(cfg.toolMaker.maxCommandParts, 6);

    final (badCfg, _) = TikoConfig.parse('''
tool_maker:
  enabled: salah
  max_tests: 99
''');
    expect(badCfg.toolMaker.enabled, isFalse);
    expect(badCfg.toolMaker.maxTests, 8);

    final (defCfg, _) = TikoConfig.parse('');
    expect(defCfg.toolMaker.enabled, isFalse);
  });

  test('TOOLMAKER-7: runtime wiring — off tanpa tool, on dengan tool',
      () async {
    final temp = await Directory.systemTemp.createTemp('tool_maker_cfg_');
    addTearDown(() => temp.delete(recursive: true));
    final configDir = Directory(p.join(temp.path, 'cfg'));
    await configDir.create();
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
tool_maker:
  enabled: ENABLED
''';
    await File(configPath).writeAsString(
      template.replaceAll('ENABLED', 'false'),
    );
    final offRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(offRt.close);
    expect(offRt.registry.get('tool_maker'), isNull);

    await File(configPath).writeAsString(
      template.replaceAll('ENABLED', 'true'),
    );
    final onRt = await TikoRuntime.create(configPath: configPath);
    addTearDown(onRt.close);
    expect(onRt.registry.get('tool_maker'), isNotNull);
  });
}
