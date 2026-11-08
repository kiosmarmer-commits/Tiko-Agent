import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('inv_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  Future<ProcessResult> hostRun(List<String> parts) =>
      Process.run(parts.first, parts.skip(1).toList());

  InvariantGuard guard() => InvariantGuard(
        workspaceRoot: tmp.path,
        commandRunner: hostRun,
      );

  test('exit0: command sukses vs gagal', () async {
    final g = guard();
    g.declare(const [
      InvariantSpec(id: 'I1', kind: 'exit0', target: 'dart --version'),
      InvariantSpec(id: 'I2', kind: 'exit0', target: 'dart --badflag'),
    ]);
    final results = await g.verify();
    expect(results[0].ok, isTrue);
    expect(results[1].ok, isFalse);
    expect(results[1].detail, contains('exit'));
  });

  test('unchanged: file utuh vs dimodifikasi', () async {
    final g = guard();
    File('${tmp.path}/a.txt').writeAsStringSync('satu');
    g.declare(const [
      InvariantSpec(id: 'U1', kind: 'unchanged', target: 'a.txt'),
    ]);
    var results = await g.verify();
    expect(results.single.ok, isTrue);
    File('${tmp.path}/a.txt').writeAsStringSync('diubah-lagi');
    results = await g.verify();
    expect(results.single.ok, isFalse);
  });

  test('declare mengganti deklarasi lama', () async {
    final g = guard();
    g.declare(const [
      InvariantSpec(id: 'I1', kind: 'exit0', target: 'dart --version'),
    ]);
    g.declare(const [
      InvariantSpec(id: 'J1', kind: 'exit0', target: 'dart --version'),
    ]);
    final results = await g.verify();
    expect(results.length, 1);
    expect(results.single.id, 'J1');
  });

  test('verify tanpa deklarasi kosong', () async {
    final g = guard();
    expect(await g.verify(), isEmpty);
  });

  test('tool declare + check + validasi kind', () async {
    final g = guard();
    final declare = InvariantDeclareTool(guard: g);
    final check = InvariantCheckTool(guard: g);
    final r1 = await declare.run({
      'invariants': [
        {'id': 'I1', 'kind': 'exit0', 'target': 'dart --version'},
      ],
    }, ctx());
    expect(r1.isError, isFalse);
    final r2 = await check.run({}, ctx());
    expect(r2.isError, isFalse);
    expect(r2.content, contains('OK'));
    final r3 = await declare.run({
      'invariants': [
        {'id': 'X1', 'kind': 'bad', 'target': 'x'},
      ],
    }, ctx());
    expect(r3.isError, isTrue);
    expect(r3.content, contains('kind'));
  });

  test('check tool tanpa deklarasi error', () async {
    final r = await InvariantCheckTool(guard: guard()).run({}, ctx());
    expect(r.isError, isTrue);
  });
}
