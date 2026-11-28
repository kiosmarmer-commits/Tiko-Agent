import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

ToolContext _ctx() => ToolContext(
      session: Session(id: 's-routine', channel: 'test', userKey: 'u'),
      workspacePath: Directory.systemTemp.path,
    );

RoutineRunner _runner(
  RoutineStore store,
  List<(String, bool)> executed, {
  void Function(String, Map<String, dynamic>)? emitEvent,
}) {
  return RoutineRunner(
    store: store,
    emitEvent: emitEvent,
    executeStep: (step, ctx) async {
      final fails = step.args['fail'] == true;
      executed.add((step.tool, !fails));
      return ToolResult(
        callId: '',
        content: fails ? 'simulasi gagal' : 'ok',
        isError: fails,
      );
    },
  );
}

void main() {
  late String dataDir;
  setUp(() async {
    dataDir =
        await Directory.systemTemp.createTemp('routine_test').then((d) => d.path);
  });

  tearDown(() async {
    await Directory(dataDir).delete(recursive: true);
  });

  test('ROUTINE-1: recorder hanya merekam langkah sukses dan menghormati cap',
      () {
    final recorder = RoutineRecorder(maxSteps: 2, maxArgsChars: 100);
    expect(recorder.isRecording('s-1'), isFalse);
    expect(recorder.start('s-1'), isTrue);
    expect(recorder.start('s-1'), isFalse);
    recorder.record('s-1', 'echo', {'text': 'halo'}, isError: false);
    recorder.record('s-1', 'shell', {'cmd': 'x'}, isError: true);
    recorder.record('s-1', 'list_dir', {'path': '.'}, isError: false);
    recorder.record('s-1', 'extra', {}, isError: false);
    final steps = recorder.stop('s-1');
    expect(recorder.isRecording('s-1'), isFalse);
    expect(steps.length, 2);
    expect(steps[0].tool, 'echo');
    expect(steps[1].tool, 'list_dir');
    expect(recorder.stop('s-1'), isEmpty);
  });

  test('ROUTINE-2: recorder memotong argumen string panjang', () {
    final recorder = RoutineRecorder(maxSteps: 8, maxArgsChars: 10);
    recorder.start('s-1');
    recorder.record('s-1', 'echo', {
      'text': 'a' * 500,
      'flag': true,
    }, isError: false);
    final steps = recorder.stop('s-1');
    expect((steps.single.args['text'] as String).length, 10);
    expect(steps.single.args['flag'], true);
  });

  test('ROUTINE-3: replay deterministik fail-fast + laporan lengkap', () async {
    final store = RoutineStore(dataDir: dataDir);
    await store.save(RoutineRecipe(
      id: 'rutin-1',
      name: 'Rutin 1',
      steps: [
        RoutineStep(tool: 'echo', args: {'text': 'satu'}),
        RoutineStep(tool: 'shell', args: {'fail': true}),
        RoutineStep(tool: 'echo', args: {'text': 'tiga'}),
      ],
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    final executed = <(String, bool)>[];
    final events = <String>[];
    final runner = _runner(store, executed, emitEvent: (e, payload) {
      events.add(e);
    });
    final report = await runner.run('rutin-1', ctx: _ctx());
    expect(report.ok, isFalse);
    expect(report.executed, 2);
    expect(executed.map((e) => e.$1), ['echo', 'shell']);
    expect(report.steps.last.ok, isFalse);
    expect(report.error, contains('langkah 1'));
    expect(events, contains('routine.run'));

    final okRun = await _runner(store, <(String, bool)>[])
        .run('rutin-1', ctx: _ctx(), continueOnError: true);
    expect(okRun.ok, isFalse);
    expect(okRun.executed, 3);
  });

  test('ROUTINE-4: dry run tidak mengeksekusi dan tidak mengubah statistik',
      () async {
    final store = RoutineStore(dataDir: dataDir);
    await store.save(RoutineRecipe(
      id: 'rutin-dry',
      name: 'Dry',
      steps: [RoutineStep(tool: 'echo', args: {'text': 'x'})],
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    final executed = <(String, bool)>[];
    final report = await _runner(store, executed).run(
      'rutin-dry',
      ctx: _ctx(),
      dryRun: true,
    );
    expect(report.ok, isTrue);
    expect(report.dryRun, isTrue);
    expect(executed, isEmpty);
    expect(store.get('rutin-dry')!.runCount, 0);
  });

  test('ROUTINE-5: store persisten, id valid, file korup dilewati', () async {
    final store = RoutineStore(dataDir: dataDir);
    await store.save(RoutineRecipe(
      id: 'rutin-persist',
      name: 'Persist',
      steps: [RoutineStep(tool: 'echo', args: {'text': 'x'})],
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    final bad = File(p.join(dataDir, 'routines', 'bad.json'));
    await bad.writeAsString('{tidak json');
    final store2 = RoutineStore(dataDir: dataDir);
    await store2.load();
    expect(store2.get('rutin-persist'), isNotNull);
    expect(store2.get('bad'), isNull);
    expect(store2.list().length, 1);
    expect(await store2.delete('rutin-persist'), isTrue);
    expect(await store2.delete('rutin-persist'), isFalse);
  });

  test('ROUTINE-6: tool routine — alur record → stop → run → delete',
      () async {
    final store = RoutineStore(dataDir: dataDir);
    await store.load();
    final recorder = RoutineRecorder();
    recorder.start('s-live');
    recorder.record('s-live', 'echo', {'text': 'halo'}, isError: false);
    final runner = RoutineRunner(
      store: store,
      executeStep: (step, ctx) async =>
          const ToolResult(callId: '', content: 'ok'),
    );
    final tool = RoutineTool(store: store, recorder: recorder, runner: runner);
    final ctx = _ctx();

    final started = await tool.run(
        {'action': 'record_start', 'session': 's-live'}, ctx);
    expect(started.isError, isTrue);
    expect(started.content, contains('sudah sedang merekam'));

    final stopped =
        await tool.run({'action': 'record_stop', 'session': 's-live', 'name': 'sapa-halo'}, ctx);
    expect(stopped.isError, isFalse);
    expect(stopped.content, contains('1 langkah'));

    final invalidName = await tool.run(
        {'action': 'record_stop', 'session': 's-live', 'name': 'Nama!'}, ctx);
    expect(invalidName.isError, isTrue);

    final list = await tool.run({'action': 'list'}, ctx);
    expect(list.content, contains('sapa-halo'));

    final run = await tool.run({'action': 'run', 'name': 'sapa-halo'}, ctx);
    expect(run.isError, isFalse);
    final report = jsonDecode(run.content) as Map<String, dynamic>;
    expect(report['ok'], true);
    expect(store.get('sapa-halo')!.runCount, 1);

    final deleted =
        await tool.run({'action': 'delete', 'name': 'sapa-halo'}, ctx);
    expect(deleted.isError, isFalse);
    expect(store.exists('sapa-halo'), isFalse);
  });

  test('ROUTINE-7: config parser fail-open + default off', () {
    final (cfg, _) = TikoConfig.parse('agent:\n  id: x\n');
    expect(cfg.routine.enabled, isFalse);
    final (parsed, _) = TikoConfig.parse('routine:\n  enabled: true\n'
        '  max_steps: 999\n'
        '  max_args_chars: 10\n');
    expect(parsed.routine.enabled, isTrue);
    expect(parsed.routine.maxSteps, 64);
    expect(parsed.routine.maxArgsChars, 2000);
  });
}
