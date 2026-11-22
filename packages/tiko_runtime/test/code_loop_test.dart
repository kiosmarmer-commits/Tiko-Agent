import 'dart:io';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// Fase B — loop coding/debugging otomatis: gate objektif (exit code),
/// umpan balik error ke turn berikutnya, bounded iterations, checkpoint.
/// Semua deterministik offline: verifikasi memakai script sh yang dibuat
/// in-test, fakor waktu nol.
void main() {
  late Directory tmp;
  late WorkspaceCheckpointer checkpointer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_fixloop_');
    checkpointer = WorkspaceCheckpointer(workspaceRoot: tmp.path);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// Script probe: gagal (exit 1) selama hitungan di bawah [passAt], lalu
  /// lulus. Menghitung berapa kali dieksekusi via count.txt di workspace.
  File makeProbeScript(int passAt) {
    final f = File('${tmp.path}/probe_fix.sh');
    f.writeAsStringSync('#!/bin/sh\n'
        'n=0\n'
        '[ -f count.txt ] && n=\$(cat count.txt)\n'
        'n=\$((n+1))\n'
        'echo \$n > count.txt\n'
        'if [ \$n -lt $passAt ]; then\n'
        '  echo "err sintetis percobaan \$n" >&2\n'
        '  exit 1\n'
        'fi\n'
        'echo ok\n');
    return f;
  }

  CodeLoopRunner runner({
    required Future<ChatRunResult> Function(String prompt) onTurn,
    int maxOutputChars = 6000,
  }) =>
      CodeLoopRunner(
        runTurn: onTurn,
        workspacePath: tmp.path,
        checkpointer: checkpointer,
        maxOutputChars: maxOutputChars,
      );

  test('lulus di iterasi pertama → success + checkpoint dibuat', () async {
    final r = await runner(
      onTurn: (prompt) async => const ChatRunResult(
        text: 'selesai', success: true, tokensUsed: 7, toolCallCount: 2,
      ),
    ).run(task: 'rapikan kode', verifyCommand: 'true', maxIterations: 3);
    expect(r.success, isTrue);
    expect(r.iterations, 1);
    expect(r.verifyRuns.single.ok, isTrue);
    expect(r.checkpointId, isNotNull);
    expect(
      Directory('${tmp.path}/.tiko/checkpoints/${r.checkpointId}')
          .existsSync(),
      isTrue,
    );
    expect(r.summary, contains('lulus pada iterasi 1'));
    expect(r.tokensUsed, 7);
    expect(r.toolCallCount, 2);
  });

  test('gagal 2x lalu lulus → prompt berikutnya berisi umpan balik error',
      () async {
    makeProbeScript(3);
    final prompts = <String>[];
    final r = await runner(
      onTurn: (prompt) {
        prompts.add(prompt);
        return Future.value(ChatRunResult(
          text: 'coba ${prompts.length}', success: true,
        ));
      },
    ).run(task: 'perbaiki bug', verifyCommand: 'sh probe_fix.sh',
        maxIterations: 3);
    expect(r.success, isTrue);
    expect(r.iterations, 3);
    expect(prompts, hasLength(3));
    expect(prompts[0], contains('Tugas coding/debugging: perbaiki bug'));
    expect(prompts[0], contains('sh probe_fix.sh'));
    expect(prompts[1], contains('GAGAL'));
    expect(prompts[1], contains('err sintetis percobaan 1'));
    expect(prompts[1], contains('perbaiki bug'));
    expect(prompts[2], contains('iterasi 2'));
  });

  test('gagal terus → success false + jalur pulih dari checkpoint jujur',
      () async {
    makeProbeScript(99);
    final r = await runner(
      onTurn: (prompt) async => const ChatRunResult(
        text: 'coba', success: true,
      ),
    ).run(task: 'x', verifyCommand: 'sh probe_fix.sh', maxIterations: 2);
    expect(r.success, isFalse);
    expect(r.iterations, 2);
    expect(r.verifyRuns, hasLength(2));
    expect(r.summary, contains('masih gagal di iterasi 2'));
    expect(r.summary, contains('rollback'));
  });

  test('runTurn throw → gagal jujur, tidak throw, verifikasi tidak jalan',
      () async {
    final r = await runner(
      onTurn: (prompt) => Future.error(StateError('provider down')),
    ).run(task: 'x', verifyCommand: 'true', maxIterations: 3);
    expect(r.success, isFalse);
    expect(r.iterations, 0);
    expect(r.verifyRuns, isEmpty);
    expect(r.summary, contains('gagal di iterasi 1'));
    expect(r.summary, contains('checkpoint'));
  });

  test('metachar di verify command → setiap iterasi gagal jujur', () async {
    final r = await runner(
      onTurn: (prompt) async => const ChatRunResult(
        text: 'coba', success: true,
      ),
    ).run(
      task: 'x',
      verifyCommand: 'true && echo injected',
      maxIterations: 2,
    );
    expect(r.success, isFalse);
    expect(r.verifyRuns.every((v) => v.output.contains('Metacharacter')),
        isTrue);
  });

  test('maxIterations di-clamp 1..8, bukan diam-diam dilepas', () async {
    makeProbeScript(99);
    var turns = 0;
    final r = await runner(
      onTurn: (prompt) {
        turns++;
        return Future.value(const ChatRunResult(text: 'coba', success: true));
      },
    ).run(task: 'x', verifyCommand: 'sh probe_fix.sh', maxIterations: 99);
    expect(turns, 8);
    expect(r.iterations, 8);
  });

  test('umpan balik output terpotong ke tail + penanda jujur', () async {
    final prompts = <String>[];
    final probeFile = File('${tmp.path}/probe_fix.sh');
    probeFile.writeAsStringSync(
        '#!/bin/sh\ncat probe_big.txt >&2\nexit 1\n');
        File('${tmp.path}/probe_big.txt').writeAsStringSync(
        List.generate(500, (i) => 'baris-$i').join('\n'));
    final r = await runner(
      onTurn: (prompt) {
        prompts.add(prompt);
        return Future.value(const ChatRunResult(text: 'coba', success: true));
      },
      maxOutputChars: 60,
    ).run(task: 'x', verifyCommand: 'sh probe_fix.sh', maxIterations: 2);
    expect(r.success, isFalse);
    expect(prompts[1], contains('[tail terpotong ke 60 karakter terakhir]'));
    expect(prompts[1], contains('baris-499'));
    expect(prompts[1].contains('baris-0'), isFalse,
        reason: 'kepala output tidak dibawa');
  });
}
