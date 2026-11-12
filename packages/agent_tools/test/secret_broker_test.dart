import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('secbr_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  Future<ProcessResult> hostRun(List<String> parts) =>
      Process.run(parts.first, parts.skip(1).toList());

  SecretBrokerTool tool() => SecretBrokerTool(
        sandbox: SandboxRunner(
          kind: SandboxKind.none,
          workspacePath: tmp.path,
        ),
        secretSource: () => const {'MY_KEY': 'abc123'},
        commandRunner: hostRun,
      );

  test('nilai secret di-redact dari output nyata', () async {
    final r = await tool().run({
      'command': 'echo {{secret:MY_KEY}}',
      'secrets': ['MY_KEY'],
    }, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('[REDACTED:MY_KEY]'));
    expect(r.content, isNot(contains('abc123')));
  });

  test('stdout dan stderr keduanya di-redact', () async {
    final t = SecretBrokerTool(
      sandbox: SandboxRunner(
        kind: SandboxKind.none,
        workspacePath: tmp.path,
      ),
      secretSource: () => const {'MY_KEY': 'abc123'},
      commandRunner: (parts) async =>
          ProcessResult(1, 1, 'ok abc123', 'err abc123'),
    );
    final r = await t.run({
      'command': 'echo {{secret:MY_KEY}}',
      'secrets': ['MY_KEY'],
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('ok [REDACTED:MY_KEY]'));
    expect(r.content, contains('err [REDACTED:MY_KEY]'));
    expect(r.content, isNot(contains('abc123')));
  });

  test('secret tidak tersedia gagal tertutup', () async {
    final r = await tool().run({
      'command': 'echo {{secret:MISSING}}',
      'secrets': ['MISSING'],
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('MISSING'));
  });

  test('nilai dengan spasi ditolak', () async {
    final t = SecretBrokerTool(
      sandbox: SandboxRunner(
        kind: SandboxKind.none,
        workspacePath: tmp.path,
      ),
      secretSource: () => const {'BAD': 'abc 123'},
      commandRunner: hostRun,
    );
    final r = await t.run({
      'command': 'echo {{secret:BAD}}',
      'secrets': ['BAD'],
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('berbahaya'));
  });

  test('placeholder tidak ada di command ditolak', () async {
    final r = await tool().run({
      'command': 'echo hello',
      'secrets': ['MY_KEY'],
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('Placeholder'));
  });

  test('sandbox none tanpa runner gagal tertutup', () async {
    final t = SecretBrokerTool(
      sandbox: SandboxRunner(
        kind: SandboxKind.none,
        workspacePath: tmp.path,
      ),
      secretSource: () => const {'MY_KEY': 'abc123'},
    );
    final r = await t.run({
      'command': 'echo {{secret:MY_KEY}}',
      'secrets': ['MY_KEY'],
    }, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('error'));
  });
}
