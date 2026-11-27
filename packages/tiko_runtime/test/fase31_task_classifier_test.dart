import 'dart:io';

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
task_classifier:
  enabled: ENABLED
  fast_max_chars: 200
  deep_keywords:
    - migration plan
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

void main() {
  group('TaskClassifier heuristik', () {
    const classifier = TaskClassifier();

    test('TC-1: pertanyaan pendek tanpa sinyal → fast', () {
      final a = classifier.classify('Halo, apa kabar?');
      expect(a.mode, TaskMode.fast);
      expect(a.signals, isEmpty);
      expect(a.inputChars, 'Halo, apa kabar?'.length);
    });

    test('TC-2: sinyal coding → coding', () {
      final a = classifier.classify(
          'Perbaiki kode di main.dart, ada build error saat compile.');
      expect(a.mode, TaskMode.coding);
      expect(a.signals, contains('file_extension'));
      expect(a.matchedKeywords, isNotEmpty);
    });

    test('TC-3: code fence → coding', () {
      final a = classifier.classify('Tolong cek:\n```dart\nvoid main() {}\n```');
      expect(a.mode, TaskMode.coding);
      expect(a.signals, contains('code_fence'));
    });

    test('TC-4: sinyal research → research', () {
      final a = classifier
          .classify('Tolong riset mendalam tentang provider LLM terbaru.');
      expect(a.mode, TaskMode.research);
    });

    test('TC-5: sinyal knowledge → knowledge', () {
      final a = classifier.classify('Apa ringkasan di dokumen internal saya?');
      expect(a.mode, TaskMode.knowledge);
    });

    test('TC-6: sinyal plan → plan', () {
      final a = classifier.classify('Buat rencana langkah demi langkah migrasi.');
      expect(a.mode, TaskMode.plan);
    });

    test('TC-7: sinyal deep → deepReasoning', () {
      final a = classifier.classify('Evaluasi trade-off arsitektur ini.');
      expect(a.mode, TaskMode.deepReasoning);
    });

    test('TC-8: aksi tool → tool', () {
      final a = classifier.classify('Tolong jadwalkan rapat besok jam 9.');
      expect(a.mode, TaskMode.tool);
    });

    test('TC-9: input panjang tanpa sinyal → tool (bukan fast)', () {
      final long = 'Tolong bantu saya memahami proyek ini secara umum. ' * 10;
      final a = classifier.classify(long);
      expect(a.mode, TaskMode.tool);
      expect(a.signals, contains('long_input'));
    });

    test('TC-10: perintah internal tidak diklasifikasi', () {
      final a = classifier.classify('/help', internalCommand: true);
      expect(a.mode, TaskMode.fast);
      expect(a.signals, isEmpty);
    });

    test('TC-11: keyword custom dari config dipakai', () {
      const cfg = TaskClassifierCfg(
        enabled: true,
        extraKeywords: {
          'deep': ['migration plan'],
        },
      );
      final a = TaskClassifier(config: cfg)
          .classify('Kami butuh migration plan untuk database.');
      expect(a.mode, TaskMode.deepReasoning);
      expect(a.signals, contains('deep_keyword_custom'));
    });

    test('TC-12: deterministik — input sama → hasil sama', () {
      const input = 'Tolong buatkan file laporan.txt lalu kirim email.';
      expect(
        classifier.classify(input).toJson(),
        classifier.classify(input).toJson(),
      );
    });
  });

  test('TC-13: parser config — section task_classifier diparse, fail-open',
      () {
    final (cfg, issues) = TikoConfig.parse('''
task_classifier:
  enabled: true
  fast_max_chars: 120
  deep_keywords:
    - migration plan
''');
    expect(issues.where((i) => i.fatal), isEmpty);
    expect(cfg.taskClassifier.enabled, isTrue);
    expect(cfg.taskClassifier.fastMaxChars, 120);
    expect(cfg.taskClassifier.extraKeywords['deep'], ['migration plan']);

    final (badCfg, _) = TikoConfig.parse('''
task_classifier:
  enabled: oops
  fast_max_chars: tidak
  deep_keywords: bukan-list
''');
    expect(badCfg.taskClassifier.enabled, isTrue, reason: 'fail-open default');
    expect(badCfg.taskClassifier.fastMaxChars, 200);
    expect(badCfg.taskClassifier.extraKeywords, isEmpty);

    final (defCfg, _) = TikoConfig.parse('');
    expect(defCfg.taskClassifier.enabled, isTrue, reason: 'default on');
  });

  test('TC-14: runtime wiring — event task.mode + ChatRunResult.taskMode',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_tc_on_');
    addTearDown(() => temp.delete(recursive: true));
    final rt = await TikoRuntime.create(
      configPath: await _prepare(temp, enabled: true),
    );
    addTearDown(rt.close);

    final result = await rt.chatWithStatus(
      'Halo, apa kabar?',
      sessionId: 's-tc',
    );
    expect(result.taskMode, 'fast');
    expect(
      rt.events.recent(limit: 20).any((e) => e['type'] == 'task.mode'),
      isTrue,
      reason: 'event task.mode harus dipancarkan',
    );
    final ev = rt.events.recent(limit: 20).firstWhere(
          (e) => e['type'] == 'task.mode',
        );
    expect(ev['mode'], 'fast');
    expect(ev['input_chars'], isPositive);

    final resultJson = result.toJson();
    expect(resultJson['task_mode'], 'fast');
  });

  test('TC-15: runtime wiring — disabled → mode kosong tanpa event',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_tc_off_');
    addTearDown(() => temp.delete(recursive: true));
    final rt = await TikoRuntime.create(
      configPath: await _prepare(temp, enabled: false),
    );
    addTearDown(rt.close);

    final result = await rt.chatWithStatus('Halo?', sessionId: 's-tc-off');
    expect(result.taskMode, isEmpty);
    expect(
      rt.events.recent(limit: 20).any((e) => e['type'] == 'task.mode'),
      isFalse,
    );
  });

  test('TC-16: perintah internal (/…) tidak diklasifikasi', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_tc_cmd_');
    addTearDown(() => temp.delete(recursive: true));
    final rt = await TikoRuntime.create(
      configPath: await _prepare(temp, enabled: true),
    );
    addTearDown(rt.close);

    await rt.chatWithStatus('/help', sessionId: 's-tc-cmd');
    final modes = rt.events
        .recent(limit: 50)
        .where((e) => e['type'] == 'task.mode')
        .toList();
    expect(modes, isEmpty,
        reason: 'perintah internal tidak lewat classifier');
  });
}
