import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String get _fixturePath {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidates = [
      p.join(dir.path, 'test', 'fixtures', 'line_plugin.dart'),
      p.join(dir.path, 'packages', 'agent_core', 'test', 'fixtures',
          'line_plugin.dart'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    if (dir.path == dir.parent.path) break;
    dir = dir.parent;
  }
  fail('fixture line_plugin.dart tidak ditemukan dari ${Directory.current.path}');
}

ProcessPlugin _spawn(String mode, {Duration? timeout}) => ProcessPlugin(
      name: 'line-$mode',
      command: Platform.resolvedExecutable,
      args: [_fixturePath, mode],
      workingDirectory: Directory.current.path,
      hookTimeout: timeout ?? const Duration(seconds: 10),
    );

void main() {
  test('handshake sukses dan beforeToolCall deny untuk shell, allow lainnya',
      () async {
    final plugin = _spawn('normal');
    await plugin.init();
    expect(plugin.isAlive, isTrue);

    final deny = await plugin.beforeToolCall(const ToolHookInput(
      toolName: 'shell',
      args: {'cmd': 'ls'},
      sessionId: 's1',
    ));
    expect(deny.allowed, isFalse);
    expect(deny.reason, contains('shell diblokir'));

    final allow = await plugin.beforeToolCall(const ToolHookInput(
      toolName: 'read_file',
      args: {'path': 'a.txt'},
      sessionId: 's1',
    ));
    expect(allow.allowed, isTrue);

    await plugin.onSessionStart('s1');
    await plugin.dispose();
    expect(plugin.isAlive, isFalse);
  });

  test('mode hang: hook timeout melempar StateError', () async {
    final plugin = _spawn('hang', timeout: const Duration(milliseconds: 400));
    await plugin.init();

    await expectLater(
      plugin.beforeToolCall(const ToolHookInput(
        toolName: 'read_file',
        args: {},
        sessionId: 's1',
      )),
      throwsA(isA<StateError>()),
    );

    await plugin.dispose();
  });

  test('mode crash: child keluar, hook berikutnya dead (StateError)',
      () async {
    final plugin = _spawn('crash');
    await plugin.init();

    final input = const ToolHookInput(
      toolName: 'read_file',
      args: {},
      sessionId: 's1',
    );
    await expectLater(
      plugin.afterToolCall(input, 'ok', false),
      throwsA(isA<StateError>()),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (plugin.isAlive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(plugin.isAlive, isFalse);

    await expectLater(
      plugin.beforeToolCall(input),
      throwsA(isA<StateError>()),
    );
  });
}
