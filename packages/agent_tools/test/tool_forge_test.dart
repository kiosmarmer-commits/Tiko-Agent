import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

ProcessResult _pr({int exitCode = 0, String out = '', String err = ''}) =>
    ProcessResult(0, exitCode, out, err);

void main() {
  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: '.',
      );

  test('create menolak nama yang sudah dipakai', () async {
    final forge = ToolForge();
    final tool = ToolForgeTool(
      forge: forge,
      hasTool: (name) => name == 'grep',
      registerTool: (_) {},
    );
    final res = await tool.run({
      'name': 'grep',
      'description': 'duplikat',
      'command': 'echo hi',
      'tests': [
        {'input': {}, 'expect_contains': 'hi'},
      ],
    }, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('sudah dipakai'));
  });

  test('create gagal ketika uji kontrak tidak lulus', () async {
    final forge = ToolForge(
      commandRunner: (parts) async => _pr(exitCode: 1),
    );
    final tool = ToolForgeTool(
      forge: forge,
      hasTool: (_) => false,
      registerTool: (_) => fail('tidak boleh terpasang'),
    );
    final res = await tool.run({
      'name': 'bad_tool',
      'description': 'selalu gagal',
      'command': 'run bad',
      'tests': [
        {'input': {'a': 1}},
      ],
    }, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('TIDAK dipasang'));
  });

  test('create fail-closed tanpa runner dan tanpa sandbox', () async {
    final tool = ToolForgeTool(
      forge: ToolForge(),
      hasTool: (_) => false,
      registerTool: (_) => fail('tidak boleh terpasang'),
    );
    final res = await tool.run({
      'name': 'no_sandbox',
      'description': 'tanpa sandbox',
      'command': 'echo hi',
      'tests': [
        {'input': {}, 'expect_contains': 'hi'},
      ],
    }, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('fail-closed'));
  });

  test('create memasang tool setelah uji kontrak lulus', () async {
    final forge = ToolForge(
      commandRunner: (parts) async {
        expect(parts.last, contains('"x"'));
        return _pr(out: 'hasil ok');
      },
    );
    final registered = <Tool>[];
    final tool = ToolForgeTool(
      forge: forge,
      hasTool: (_) => false,
      registerTool: registered.add,
    );
    final res = await tool.run({
      'name': 'my_check',
      'description': 'cek khusus',
      'command': 'python3 check.py',
      'tests': [
        {'input': {'x': 1}, 'expect_contains': 'hasil'},
      ],
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('terpasang'));
    expect(registered, hasLength(1));
    expect(registered.single.spec.name, equals('my_check'));
    final run = await registered.single.run({'x': 2}, ctx());
    expect(run.isError, isFalse);
    expect(run.content, contains('hasil ok'));
  });

  test('ForgedTool melaporkan exit != 0 sebagai error', () async {
    final forge = ToolForge(
      commandRunner: (parts) async => _pr(exitCode: 3, err: 'boom'),
    );
    final def = const ForgedToolDef(
      name: 'fail_tool',
      description: 'selalu gagal',
      command: ['run'],
      tests: [ForgeTest(input: {})],
    );
    final res = await ForgedTool(def: def, forge: forge).run({}, ctx());
    expect(res.isError, isTrue);
    expect(res.content, contains('boom'));
  });
}
