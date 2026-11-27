import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _config = '''
profile: default
workspace: WORKSPACE
data_dir: DATA
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
security:
  mode: ask
mcp:
  servers: []
deep_solve:
  enabled: ENABLED
  branching: 2
  depth: 2
  max_llm_calls: 8
''';

Future<String> _prepare(Directory temp, {required bool enabled}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    _config
        .replaceAll('WORKSPACE', temp.path)
        .replaceAll('DATA', p.join(temp.path, 'data'))
        .replaceAll('ENABLED', enabled ? 'true' : 'false'),
  );
  return config.path;
}

/// LLM berskrip: jawaban tergantung kata kunci prompt (judge/expand/refine/
/// steps) sehingga alur ToT bisa diuji deterministik.
class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm();

  int calls = 0;
  final List<String> prompts = [];

  @override
  String get id => 'scripted-deep-solve';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    calls++;
    final prompt = req.messages.last.content;
    prompts.add(prompt);
    if (prompt.contains('SCORE:')) {
      yield LlmTextDelta('SCORE: 0.80\nREASON: pendekatan layak diuji.');
      return;
    }
    if (prompt.contains('maksimal 6 langkah')) {
      yield LlmTextDelta('1. Siapkan data uji\n2. Jalankan pendekatan\n'
          '3. Verifikasi hasil');
      return;
    }
    if (prompt.contains('Perdalam')) {
      yield LlmTextDelta('1. Varian A lebih konkret\n2. Varian B lebih murah');
      return;
    }
    yield LlmTextDelta(
        '1. Pendekatan mikro-benchmark\n2. Pendekatan analisis statis');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _ErrorLlm implements LlmProvider {
  const _ErrorLlm();

  @override
  String get id => 'error-deep-solve';

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: false, streaming: true, maxContext: 8192);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield const LlmError('provider mati');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

void main() {
  test('DEEP-1: alur expand-judge-refine-steps menghasilkan pendekatan terbaik',
      () async {
    final llm = _ScriptedLlm();
    final bus = EventBus();
    final events = <String>[];
    bus.stream.listen((e) => events.add(e.type));
    final engine = DeepSolveEngine(
      llmProvider: llm,
      config: const DeepSolveCfg(enabled: true, branching: 2, depth: 2),
      events: bus,
    );

    final result = await engine.solve(
        'Optimalkan waktu build CI repo Dart yang besar tanpa merusak parity.');

    expect(result.error, isNull);
    expect(result.approach, isNotEmpty);
    expect(result.steps, hasLength(3));
    expect(result.steps.first, startsWith('Siapkan data uji'));
    expect(result.explored, isNotEmpty);
    expect(result.llmCalls, greaterThanOrEqualTo(4));
    expect(result.capped, isFalse);
    expect(
      result.explored.every((c) => c.score >= 0 && c.score <= 1),
      isTrue,
      reason: 'semua kandidat ter-judge dalam rentang 0..1',
    );
    expect(events, contains('deep_solve.done'));

    final json = result.toJson();
    expect(json['task'], isA<String>());
    expect((json['explored'] as List).map((e) => e['score']), isNotEmpty);
  });

  test('DEEP-2: LLM mati degenerate ke kandidat root tanpa raise', () async {
    final engine = DeepSolveEngine(
      llmProvider: const _ErrorLlm(),
      config: const DeepSolveCfg(enabled: true),
    );

    final result = await engine.solve('Task berat apa pun.');

    expect(result.error, isNull, reason: 'kegagalan LLM tidak boleh raise');
    expect(result.approach, 'Task berat apa pun.');
    expect(result.steps, hasLength(1));
    expect(result.llmCalls, greaterThanOrEqualTo(1));
  });

  test('DEEP-3: cap max_llm_calls memotong eksplorasi (capped=true)',
      () async {
    final engine = DeepSolveEngine(
      llmProvider: _ScriptedLlm(),
      config: const DeepSolveCfg(enabled: true, maxLlmCalls: 2),
    );

    final result = await engine.solve('Task eksplorasi berat.');

    expect(result.llmCalls, lessThanOrEqualTo(2));
    expect(result.capped, isTrue);
    expect(result.approach, isNotEmpty);
  });

  test('DEEP-4: parseVerdict strict — tanpa SCORE valid → null', () {
    expect(DeepSolveEngine.parseVerdict('SCORE: 0.50\nREASON: oke'), isNotNull);
    expect(DeepSolveEngine.parseVerdict('SCORE: 1.2\nREASON: overflow'),
        isNull);
    expect(DeepSolveEngine.parseVerdict('SCORE: abc'), isNull);
    expect(DeepSolveEngine.parseVerdict('balasan tanpa skor'), isNull);
  });

  test('DEEP-5: tool deep_solve memvalidasi argumen task', () async {
    final engine = DeepSolveEngine(
      llmProvider: _ScriptedLlm(),
      config: const DeepSolveCfg(enabled: true),
    );
    final tool = DeepSolveTool(engine);
    final ctx = ToolContext(
      session: Session(id: 's-ds', channel: 'test', userKey: 'tester'),
      workspacePath: '.',
    );

    final missing = await tool.run({}, ctx);
    expect(missing.isError, isTrue);
    expect(missing.content, contains('task'));

    final ok = await tool.run({'task': 'uji kecil'}, ctx);
    expect(ok.isError, isFalse);
    expect(ok.content, contains('"approach"'));
  });

  test('DEEP-6: config parser — section deep_solve diparse, scalar invalid '
      'fail-open', () {
    final (cfg, issues) = TikoConfig.parse('''
deep_solve:
  enabled: true
  branching: 3
  depth: 2
  max_llm_calls: 12
  max_wall_clock_sec: 90
''');
    expect(issues.where((i) => i.fatal), isEmpty);
    expect(cfg.deepSolve.enabled, isTrue);
    expect(cfg.deepSolve.branching, 3);
    expect(cfg.deepSolve.maxLlmCalls, 12);
    expect(cfg.deepSolve.maxWallClockSec, 90);

    final (badCfg, _) = TikoConfig.parse('''
deep_solve:
  enabled: true
  branching: 99
  depth: tidak
  max_llm_calls: -5
''');
    expect(badCfg.deepSolve.branching, 2, reason: 'fail-open ke default');
    expect(badCfg.deepSolve.depth, 2);
    expect(badCfg.deepSolve.maxLlmCalls, 8);

    final (offCfg, _) = TikoConfig.parse('');
    expect(offCfg.deepSolve.enabled, isFalse, reason: 'default off');
  });

  test('DEEP-7: runtime wiring — enabled membuat tool deep_solve, disabled '
      'tidak', () async {
    final tempOn = await Directory.systemTemp.createTemp('tiko_ds_on_');
    addTearDown(() => tempOn.delete(recursive: true));
    final rtOn = await TikoRuntime.create(
      configPath: await _prepare(tempOn, enabled: true),
    );
    addTearDown(rtOn.close);
    expect(rtOn.deepSolveEngine, isNotNull);
    expect(rtOn.registry.get('deep_solve'), isNotNull);

    final tempOff = await Directory.systemTemp.createTemp('tiko_ds_off_');
    addTearDown(() => tempOff.delete(recursive: true));
    final rtOff = await TikoRuntime.create(
      configPath: await _prepare(tempOff, enabled: false),
    );
    addTearDown(rtOff.close);
    expect(rtOff.deepSolveEngine, isNull);
    expect(rtOff.registry.get('deep_solve'), isNull);
  });
}
