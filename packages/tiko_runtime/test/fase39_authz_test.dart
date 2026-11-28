import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  late String path;

  setUp(() async {
    final dir =
        await Directory.systemTemp.createTemp('authz_test');
    path = '${dir.path}${Platform.pathSeparator}authorization_memory.json';
  });

  tearDown(() async {
    final file = File(path);
    if (await file.exists()) {
      await file.parent.delete(recursive: true);
    }
  });

  test('AUTHZ-1: grant → check cocok per sesi, TTL kedaluwarsa ditolak',
      () async {
    final mem = AuthorizationMemory(
      path: path,
      ttl: const Duration(minutes: 5),
    );
    expect(
      mem.check(tool: 'shell', argsHash: 'abc', sessionId: 's-1').authorized,
      isFalse,
    );
    expect(
      await mem.grant(tool: 'shell', argsHash: 'abc', sessionId: 's-1'),
      isTrue,
    );
    expect(
      mem.check(tool: 'shell', argsHash: 'abc', sessionId: 's-1').authorized,
      isTrue,
    );
    expect(
      mem.check(tool: 'shell', argsHash: 'abc', sessionId: 's-2').authorized,
      isFalse,
      reason: 'otorisasi terikat sesi',
    );
    expect(
      mem.check(tool: 'other', argsHash: 'abc', sessionId: 's-1').authorized,
      isFalse,
      reason: 'tool berbeda',
    );
  });

  test('AUTHZ-2: never_cache_tools selalu ditolak (fail-closed)', () async {
    final mem = AuthorizationMemory(
      path: path,
      neverCacheTools: const {'tool_maker'},
    );
    expect(
      await mem.grant(tool: 'tool_maker', argsHash: 'abc', sessionId: 's-1'),
      isFalse,
    );
    expect(
      mem.check(tool: 'tool_maker', argsHash: 'abc', sessionId: 's-1')
          .authorized,
      isFalse,
    );
    expect(
      mem.check(tool: 'tool_maker', argsHash: 'abc', sessionId: 's-1').reason,
      contains('never_cache_tools'),
    );
  });

  test('AUTHZ-3: persist — entry hidup lintas instance, korup fail-open',
      () async {
    final mem = AuthorizationMemory(path: path, ttl: const Duration(hours: 1));
    await mem.grant(
      tool: 'shell',
      argsHash: 'deadbeef',
      sessionId: 's-1',
      actor: 'approval:apr_1',
    );
    final mem2 = AuthorizationMemory(path: path, ttl: const Duration(hours: 1));
    await mem2.load();
    expect(mem2.count(), 1);
    expect(
      mem2.check(tool: 'shell', argsHash: 'deadbeef', sessionId: 's-1')
          .authorized,
      isTrue,
    );

    final corrupted = File(path);
    await corrupted.writeAsString('{korup');
    final mem3 = AuthorizationMemory(path: path, ttl: const Duration(hours: 1));
    await mem3.load();
    expect(mem3.count(), 0);
  });

  test('AUTHZ-4: stableArgsHash stabil & cocok semantik ledger', () {
    final a = stableArgsHash({'cmd': 'ls -la', 'cwd': '/tmp'});
    final b = stableArgsHash({'cwd': '/tmp', 'cmd': 'ls -la'});
    expect(a, b, reason: 'urutan key tidak memengaruhi hash');
    final c = stableArgsHash({'cmd': 'ls /tmp', 'cwd': '/tmp'});
    expect(a, isNot(c));
    final d = stableArgsHash({'cmd': 'ls -la', 'cwd': '/tmp', '_cap': 'x'});
    expect(d, a, reason: 'key internal dikecualikan dari hash');
  });

  test('AUTHZ-5: revoke & clear', () async {
    final mem = AuthorizationMemory(path: path);
    await mem.grant(tool: 'shell', argsHash: 'h1', sessionId: 's-1');
    await mem.grant(tool: 'echo', argsHash: 'h2', sessionId: 's-1');
    await mem.grant(tool: 'shell', argsHash: 'h3', sessionId: 's-2');
    final removedTool = await mem.revoke(tool: 'shell', sessionId: 's-1');
    expect(removedTool, 1);
    expect(mem.count(), 2);
    final removedSession = await mem.revoke(sessionId: 's-1');
    expect(removedSession, 1);
    final cleared = await mem.revoke();
    expect(cleared, 1);
    expect(mem.snapshot(), isEmpty);
  });

  test('AUTHZ-6: tool authz — list/revoke/clear', () async {
    final mem = AuthorizationMemory(path: path);
    await mem.grant(tool: 'shell', argsHash: 'h1', sessionId: 's-1');
    final tool = AuthorizationTool(memory: mem);
    final ctx = ToolContext(
      session: Session(id: 's-1', channel: 'test', userKey: 'u'),
      workspacePath: Directory.systemTemp.path,
    );

    final listed = await tool.run({'action': 'list'}, ctx);
    expect(listed.content, contains('shell'));

    final unknown = await tool.run({'action': 'grant'}, ctx);
    expect(unknown.isError, isTrue);

    final revoked = await tool.run({'action': 'revoke', 'tool': 'shell'}, ctx);
    expect(revoked.content, contains('1 otorisasi dicabut'));
  });

  test('AUTHZ-7: config parser fail-open + default off + never-cache default',
      () {
    final (cfg, _) = TikoConfig.parse('agent:\n  id: x\n');
    expect(cfg.authorizationMemory.enabled, isFalse);
    final (parsed, _) = TikoConfig.parse('authorization_memory:\n'
        '  enabled: true\n'
        '  ttl_minutes: 1\n'
        '  max_entries: 0\n'
        '  never_cache_tools: ["shell", "echo"]\n');
    expect(parsed.authorizationMemory.enabled, isTrue);
    expect(parsed.authorizationMemory.ttlMinutes, 60);
    expect(parsed.authorizationMemory.maxEntries, 256);
    expect(parsed.authorizationMemory.neverCacheTools, ['shell', 'echo']);
    expect(
      AuthorizationMemory(
        path: path,
        neverCacheTools: Set.of(parsed.authorizationMemory.neverCacheTools),
      ).neverCacheTools,
      containsAll(['shell', 'echo']),
    );
  });
}
