import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Fase B — tool `verify_project` + `runVerification`: gate objektif
/// (exit code nyata) untuk loop coding/debugging. Fail-closed: command
/// invalid / metachar / path luar workspace jadi outcome gagal jujur.
void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_verify_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() => ToolContext(session: session, workspacePath: tmp.path);

  VerifyProjectTool tool() => VerifyProjectTool(workspaceRoot: tmp.path);

  test('perintah lulus → ok true, exit 0, output dikembalikan', () async {
    final r = await runVerification('echo halo-verifikasi',
        workspacePath: tmp.path);
    expect(r.ok, isTrue);
    expect(r.exitCode, 0);
    expect(r.output, contains('halo-verifikasi'));
  });

  test('cwd dijail ke workspace', () async {
    final r = await runVerification('pwd', workspacePath: tmp.path);
    expect(r.ok, isTrue);
    expect(r.output, contains(tmp.path));
  });

  test('exit != 0 → gagal dengan stderr ditampilkan', () async {
    final r = await runVerification('false', workspacePath: tmp.path);
    expect(r.ok, isFalse);
    expect(r.exitCode, isNot(0));
  });

  test('metacharacter shell ditolak (kontrak setara shell)', () async {
    final r = await runVerification('echo a && rm -rf x',
        workspacePath: tmp.path);
    expect(r.ok, isFalse);
    expect(r.output, contains('Metacharacter shell dilarang'));
  });

  test('argumen path di luar workspace ditolak', () async {
    final r = await runVerification('cat /etc/hostname',
        workspacePath: tmp.path);
    expect(r.ok, isFalse);
    expect(r.output, contains('di luar workspace'));
  });

  test('binary tidak ada → gagal jujur, tidak throw', () async {
    final r = await runVerification('tiko-tidak-ada-komando --x',
        workspacePath: tmp.path);
    expect(r.ok, isFalse);
    expect(r.output, contains('toolchain tidak tersedia'));
  });

  test('perintah kosong → gagal jujur', () async {
    final r = await runVerification('   ', workspacePath: tmp.path);
    expect(r.ok, isFalse);
    expect(r.output, contains('kosong'));
  });

  test('output dipotong jadi tail + penanda jujur', () async {
    // buat skrip di dalam workspace yang menghasilkan output besar
    final big = List.generate(2000, (i) => 'baris-$i').join('\n');
    final probe = File('${tmp.path}/probe_big.txt');
    probe.writeAsStringSync(big);
    final r = await runVerification('cat probe_big.txt',
        workspacePath: tmp.path);
    expect(r.ok, isTrue);
    expect(r.output.startsWith('baris-0'), isFalse,
        reason: 'harus tail, bukan kepala');
    expect(r.output, contains('[dipotong depan]'));
    expect(r.output, contains('baris-1999'));
  });

  test('run() tool: VERIFIKASI OK untuk lulus', () async {
    final r = await tool().run({'cmd': 'echo ok-loop'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('VERIFIKASI OK'));
    expect(r.content, contains('ok-loop'));
  });

  test('run() tool: VERIFIKASI GAGAL + isError untuk exit != 0', () async {
    final r = await tool().run({'cmd': 'false'}, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('VERIFIKASI GAGAL'));
  });

  test('run() tool: cmd kosong ditolak', () async {
    final r = await tool().run({'cmd': ''}, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('cmd kosong'));
  });

  test('spec: verify_project + risk high + wajib cmd', () {
    final spec = tool().spec;
    expect(spec.name, 'verify_project');
    expect(spec.risk, 'high');
    expect((spec.inputSchema['properties'] as Map).containsKey('cmd'), isTrue);
    expect((spec.inputSchema['properties'] as Map).containsKey('auto'), isTrue);
  });
}
