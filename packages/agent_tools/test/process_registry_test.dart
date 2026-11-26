import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('process_registry_test');
    session = Session(id: 's1', channel: 'cli', userKey: 'u1');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(session: session, workspacePath: tmp.path);

  ProcessRegistry registry([String? path]) => ProcessRegistry(
        checkpointPath: path ?? '${tmp.path}/proc_checkpoint.json',
      );

  test('start → poll menampilkan output dan status running', () async {
    final reg = registry();
    final bp = await reg.start([
      'sh',
      '-c',
      'echo halo-proses; sleep 5',
    ]);

    expect(bp.isRunning, isTrue);
    expect(bp.pid, greaterThan(0));

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final poll = bp.poll();
    expect(poll, contains('status: running'));
    expect(poll, contains('halo-proses'));

    final poll2 = bp.poll();
    expect(poll2, isNot(contains('halo-proses')));

    await bp.kill();
  });

  test('log menampilkan seluruh buffer', () async {
    final reg = registry();
    final bp = await reg.start(['sh', '-c', 'echo satu; echo dua']);
    await bp.wait(timeout: const Duration(seconds: 10));
    final log = bp.log();
    expect(log, contains('satu'));
    expect(log, contains('dua'));
    expect(log, contains('status: exited'));
  });

  test('stderr diberi label dan masuk buffer; exit code terekam', () async {
    final reg = registry();
    final bp = await reg.start(['sh', '-c', 'echo oops-err >&2; exit 3']);
    await bp.wait(timeout: const Duration(seconds: 10));
    expect(bp.log(), contains('oops-err'));
    expect(bp.exitCode, 3);
  });

  test('kill menghentikan proses berjalan', () async {
    final reg = registry();
    final bp = await reg.start(['sh', '-c', 'sleep 30']);
    await bp.kill();
    expect(bp.status, contains('killed'));
  });

  test('checkpoint durabel: recover memulihkan proses + buffer', () async {
    final path = '${tmp.path}/proc_checkpoint.json';
    final reg = registry(path);
    final bp = await reg.start(['sh', '-c', 'echo checkpoint-test; sleep 30']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await reg.checkpoint();
    await bp.kill();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final reg2 = registry(path);
    final recovered = await reg2.recover();
    expect(recovered, 1);
    final r = reg2.get(bp.id);
    expect(r, isNotNull);
    expect(r!.log(), contains('checkpoint-test'));
  });

  test('recover: pid yang tidak hidup lagi → exited unknown', () async {
    final path = '${tmp.path}/proc_checkpoint.json';
    final reg = registry(path);
    final bp = await reg.start(['sh', '-c', 'echo x']);
    await bp.wait(timeout: const Duration(seconds: 10));
    await reg.checkpoint();

    final reg2 = registry(path);
    await reg2.recover();
    final r = reg2.get(bp.id)!;
    expect(r.isRunning, isFalse);
  });

  test('rolling buffer memotong output dari depan', () async {
    final reg = registry();
    final bp = await reg.start([
      'sh',
      '-c',
      'for i in \$(seq 1 30000); do echo "line-\$i"; done',
    ]);
    await bp.wait(timeout: const Duration(seconds: 30));
    expect(
      bp.log().length,
      lessThanOrEqualTo(BackgroundProcess.maxBufferChars + 200),
    );
    final log = bp.log();
    expect(log, contains('line-29999'));
    expect(log, isNot(contains('\nline-0\n')));
  });

  test('env scoping: default env dikirim, environment host tidak diwariskan',
      () async {
    final reg = ProcessRegistry(
      checkpointPath: '${tmp.path}/proc_checkpoint.json',
      defaultEnv: const {'TIKO_TEST_MARKER': 'from-registry'},
    );
    final bp = await reg.start([
      'sh',
      '-c',
      'echo "marker=\$TIKO_TEST_MARKER"; echo "home=\${HOME:-unset}"',
    ]);
    await bp.wait(timeout: const Duration(seconds: 10));
    expect(bp.log(), contains('marker=from-registry'));
    expect(bp.log(), contains('home=unset'));
  });

  test('BackgroundProcessTool: start/poll/kill lewat args', () async {
    final reg = registry();
    final tool = BackgroundProcessTool(registry: reg);

    final started = await tool.run({
      'action': 'start',
      'command': ['sh', '-c', 'echo via-tool; sleep 30'],
    }, ctx());
    expect(started.isError, isFalse);
    expect(started.content, contains('Pantau dengan action=poll'));

    final id = RegExp(r'bg-\d+-\d+').firstMatch(started.content)!.group(0)!;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final polled = await tool.run({'action': 'poll', 'id': id}, ctx());
    expect(polled.content, contains('via-tool'));

    final killed = await tool.run({'action': 'kill', 'id': id}, ctx());
    expect(killed.content, contains('killed'));
  });

  test('BackgroundProcessTool: validasi args', () async {
    final tool = BackgroundProcessTool(registry: registry());

    final noCmd = await tool.run({'action': 'start'}, ctx());
    expect(noCmd.isError, isTrue);

    final noId = await tool.run({'action': 'poll'}, ctx());
    expect(noId.isError, isTrue);

    final unknownId = await tool.run({'action': 'poll', 'id': 'bg-xx'}, ctx());
    expect(unknownId.isError, isTrue);

    final badAction = await tool.run({'action': 'reboot'}, ctx());
    expect(badAction.isError, isTrue);
  });
}
