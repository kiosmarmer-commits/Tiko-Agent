import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _FakeAdvisor implements ScriptRepairAdvisor {
  _FakeAdvisor(this.patches);

  final List<String> patches;
  final List<ScriptRepairInput> calls = [];

  @override
  Future<String> proposePatch(ScriptRepairInput input) async {
    calls.add(input);
    if (calls.length > patches.length) {
      throw ScriptRepairException('advisor kehabisan patch (fake)');
    }
    return patches[calls.length - 1];
  }
}

ScriptExecutionResult ok(String out) =>
    ScriptExecutionResult(exitCode: 0, stdout: out, stderr: '');

ScriptExecutionResult fail(int code, String err) =>
    ScriptExecutionResult(exitCode: code, stdout: '', stderr: err);

void main() {
  group('SelfCorrectingScriptRunner', () {
    test('sukses pada percobaan pertama tanpa panggil advisor', () async {
      final advisor = _FakeAdvisor(['print("patched")']);
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async => ok('halo'),
      );
      final report = await runner.run(source: 'print("halo")');
      expect(report.success, isTrue);
      expect(report.output, 'halo');
      expect(report.attempts, hasLength(1));
      expect(report.attempts.single.action, 'run');
      expect(report.attempts.single.exitCode, 0);
      expect(advisor.calls, isEmpty);
      expect(report.auditSummary(), contains('sukses setelah 1 percobaan'));
    });

    test('gagal → patch → sukses (audit trail lengkap)', () async {
      final advisor = _FakeAdvisor(['print("fixed")']);
      final seenSources = <String>[];
      var call = 0;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async {
          call++;
          final src = File('$dir/run.py').readAsStringSync();
          seenSources.add(src);
          if (call == 1) return fail(1, 'NameError: x is not defined');
          return ok('done');
        },
      );
      final report = await runner.run(source: 'print(x)');
      expect(report.success, isTrue);
      expect(report.output, 'done');
      expect(seenSources[0], 'print(x)');
      expect(seenSources[1], 'print("fixed")');
      expect(
        report.attempts.map((a) => a.action).toList(),
        ['run', 'patch', 'run'],
      );
      expect(report.attempts[0].errorExcerpt, contains('NameError'));
      expect(advisor.calls.single.exitCode, 1);
      expect(advisor.calls.single.stderr, contains('NameError'));
      expect(advisor.calls.single.attempt, 1);
    });

    test('gagal terus → berhenti di maxAttempts (default 3)', () async {
      final advisor = _FakeAdvisor([
        'print("v2")',
        'print("v3")',
        'print("v4")',
      ]);
      var call = 0;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async =>
            fail(++call, 'error $call'),
      );
      final report = await runner.run(source: 'print("v1")');
      expect(report.success, isFalse);
      // 3 run + 2 patch + 1 abandon.
      expect(
        report.attempts.map((a) => a.action).toList(),
        ['run', 'patch', 'run', 'patch', 'run', 'abandon'],
      );
      expect(report.exitCode, 3);
      expect(report.error, contains('error 3'));
      expect(advisor.calls, hasLength(2)); // tidak patch lagi setelah terakhir
    });

    test('timeout diperlakukan sebagai kegagalan', () async {
      final advisor = _FakeAdvisor(['print("ok")']);
      var call = 0;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async {
          if (++call == 1) throw TimeoutException('tp', timeout);
          return ok('selesai');
        },
      );
      final report = await runner.run(source: 'print("lambat")');
      expect(report.success, isTrue);
      expect(report.attempts.first.exitCode, -1);
      expect(report.attempts.first.errorExcerpt, 'timeout');
    });

    test('tanpa advisor → jalankan sekali, gagal apa adanya', () async {
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        executorOverride: (cmd, dir, stdin, timeout) async =>
            fail(2, 'boom'),
      );
      final report = await runner.run(source: 'print("x")');
      expect(report.success, isFalse);
      expect(
        report.attempts.map((a) => a.action).toList(),
        ['run', 'abandon'],
      );
      expect(report.error, contains('boom'));
    });

    test('advisor error (ScriptRepairException) → berhenti, bukan crash',
        () async {
      final advisor = _ThrowingAdvisor();
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async =>
            fail(1, 'err'),
      );
      final report = await runner.run(source: 'print("x")');
      expect(report.success, isFalse);
      expect(report.error, contains('advisor gagal'));
      expect(report.attempts.last.errorExcerpt, contains('advisor:'));
    });

    test('patch identik ditolak (anti-loop)', () async {
      final advisor = _FakeAdvisor(['print("sama")']);
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: advisor,
        executorOverride: (cmd, dir, stdin, timeout) async =>
            fail(1, 'err'),
      );
      final report = await runner.run(source: 'print("sama")');
      expect(report.success, isFalse);
      expect(report.error, contains('identik'));
      expect(
        report.attempts.map((a) => a.action).toList(),
        ['run', 'abandon'],
      );
    });

    test('patch kosong / oversize ditolak fail-closed', () async {
      final emptyAdvisor = _FakeAdvisor(['   ']);
      final r1 = await SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: emptyAdvisor,
        executorOverride: (cmd, dir, stdin, timeout) async => fail(1, 'e'),
      ).run(source: 'print("x")');
      expect(r1.error, contains('kosong'));

      final bigAdvisor = _FakeAdvisor(['y' * 20001]);
      final r2 = await SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: bigAdvisor,
        executorOverride: (cmd, dir, stdin, timeout) async => fail(1, 'e'),
      ).run(source: 'print("x")');
      expect(r2.error, contains('batas ukuran'));
    });

    test('fail-closed: SandboxKind.none tanpa override menolak', () async {
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(kind: SandboxKind.none, workspacePath: '/tmp'),
        advisor: _FakeAdvisor(['x']),
      );
      expect(
        () => runner.run(source: 'print("x")'),
        throwsStateError,
      );
    });

    test('args dikirim sebagai stdin JSON', () async {
      String? capturedStdin;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        executorOverride: (cmd, dir, stdin, timeout) async {
          capturedStdin = stdin;
          return ok('ok');
        },
      );
      await runner.run(
        source: 'print("x")',
        args: {'nama': 'budi', 'angka': 7},
      );
      expect(capturedStdin, isNotNull);
      final decoded = jsonDecode(capturedStdin!) as Map<String, dynamic>;
      expect(decoded['nama'], 'budi');
      expect(decoded['angka'], 7);
    });

    test('validasi input: source kosong, entry_file tidak aman, command jelek',
        () async {
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        executorOverride: (cmd, dir, stdin, timeout) async => ok(''),
      );
      expect(() => runner.run(source: '   '), throwsArgumentError);
      expect(
        () => runner.run(source: 'x', entryFile: '../escape.py'),
        throwsArgumentError,
      );
      expect(
        () => runner.run(source: 'x', entryFile: '.hidden.py'),
        throwsArgumentError,
      );
      expect(
        () => runner.run(source: 'x', command: []),
        throwsArgumentError,
      );
      expect(
        () => runner.run(source: 'x' * 20001),
        throwsArgumentError,
      );
    });

    test('direktori kerja dibersihkan setelah selesai', () async {
      String? usedDir;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        executorOverride: (cmd, dir, stdin, timeout) async {
          usedDir = dir;
          return ok('ok');
        },
      );
      await runner.run(source: 'print("x")');
      expect(Directory(usedDir!).existsSync(), isFalse);
    });
  });

  group('ScriptSelfHealTool', () {
    Future<(ToolResult, List<ScriptRunReport>)> runTool(
      Map<String, dynamic> args, {
      List<String> patches = const ['print("fixed")'],
      List<ScriptExecutionResult Function()>? results,
    }) async {
      final reports = <ScriptRunReport>[];
      var call = 0;
      final runner = SelfCorrectingScriptRunner(
        sandbox: SandboxRunner(workspacePath: '/tmp'),
        advisor: _FakeAdvisor(patches),
        executorOverride: (cmd, dir, stdin, timeout) async {
          final r = results![call.clamp(0, results.length - 1)]();
          call++;
          return r;
        },
      );
      final tool = ScriptSelfHealTool(runner: runner, onReport: reports.add);
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: '/tmp',
      );
      return (await tool.run(args, ctx), reports);
    }

    test('metadata tool: risk high, timeout dibatasi 60', () {
      final tool = ScriptSelfHealTool(
        runner: SelfCorrectingScriptRunner(
          sandbox: SandboxRunner(workspacePath: '/tmp'),
          timeoutSec: 60,
          maxAttempts: 5,
        ),
      );
      expect(tool.spec.name, 'script_selfheal');
      expect(tool.spec.risk, 'high');
      expect(tool.spec.timeoutSec, 60);
    });

    test('sukses: output + audit trail; onReport terpanggil', () async {
      final (result, reports) = await runTool(
        {'source': 'print("halo")'},
        results: [() => ok('hasil')],
      );
      expect(result.isError, isFalse);
      expect(result.content, contains('hasil'));
      expect(result.content, contains('[audit]'));
      expect(result.content, contains('percobaan 1 run'));
      expect(reports, hasLength(1));
      expect(reports.single.success, isTrue);
    });

    test('gagal setelah patch: isError + audit + stderr', () async {
      final (result, reports) = await runTool(
        {'source': 'print("x")'},
        results: [() => fail(1, 'syntax error dekat baris 1')],
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('syntax error'));
      expect(result.content, contains('[audit]'));
      expect(result.content, contains('percobaan 1 run (exit 1)'));
      expect(result.content, contains('percobaan 1 patch'));
      expect(reports.single.success, isFalse);
    });

    test('source kosong → error', () async {
      final (result, _) = await runTool({'source': ''});
      expect(result.isError, isTrue);
      expect(result.content, contains('butuh source'));
    });

    test('entry_file tidak aman → error, tanpa eksekusi', () async {
      final (result, reports) = await runTool({
        'source': 'print("x")',
        'entry_file': '../evil.py',
      });
      expect(result.isError, isTrue);
      expect(reports, isEmpty);
    });
  });
}

class _ThrowingAdvisor implements ScriptRepairAdvisor {
  @override
  Future<String> proposePatch(ScriptRepairInput input) async {
    throw ScriptRepairException('LLM down');
  }
}
