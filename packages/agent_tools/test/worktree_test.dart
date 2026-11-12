import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<Directory> _initRepo() async {
  final dir = await Directory.systemTemp.createTemp('tiko_worktree_test_');
  await Process.run('git', ['init', '-q', dir.path]);
  await Process.run('git', ['-C', dir.path, 'config', 'user.email', 't@t']);
  await Process.run('git', ['-C', dir.path, 'config', 'user.name', 't']);
  await File(p.join(dir.path, 'README.md')).writeAsString('seed\n');
  await Process.run('git', ['-C', dir.path, 'add', '-A']);
  await Process.run('git', ['-C', dir.path, 'commit', '-q', '-m', 'init']);
  return dir;
}

void main() {
  late Directory repo;
  late WorktreeManager manager;

  setUp(() async {
    repo = await _initRepo();
    manager = WorktreeManager(repoRoot: repo.path);
  });

  tearDown(() async {
    try { await repo.delete(recursive: true); } catch (_) {}
  });

  test('create, list and remove a per-task worktree', () async {
    final path = await manager.create('fix-login');
    expect(Directory(path).existsSync(), isTrue);
    expect(p.basename(path), 'fix-login');

    final items = await manager.list();
    expect(items, hasLength(1));
    expect(items.single['task'], 'fix-login');
    expect(items.single['branch'], 'tiko/fix-login');

    final removed = await manager.remove('fix-login');
    expect(removed, isTrue);
    expect(Directory(path).existsSync(), isFalse);
    expect(await manager.list(), isEmpty);
  });

  test('rejects unsafe task ids and duplicate worktrees', () async {
    await expectLater(
      () => manager.create('../escape'),
      throwsA(isA<ArgumentError>()),
    );
    // Task ids are normalized to lowercase before use.
    final upper = await manager.create('UPPER');
    expect(p.basename(upper), 'upper');
    await manager.remove('upper');
    await manager.create('task-a');
    await expectLater(
      () => manager.create('task-a'),
      throwsA(isA<StateError>()),
    );
  });

  test('tool surface: create/list/remove roundtrip', () async {
    final tool = WorktreeTool(manager);
    final ctx = ToolContext(
      session: Session(id: 's1', channel: 'test', userKey: 'u'),
      workspacePath: repo.path,
    );

    final created = await tool.run({'action': 'create', 'task': 'feat-x'}, ctx);
    expect(created.isError, isFalse);
    expect(created.content, contains('.tiko-worktrees'));

    final listed = await tool.run({'action': 'list'}, ctx);
    expect(listed.content, contains('feat-x'));

    final removed = await tool.run({'action': 'remove', 'task': 'feat-x'}, ctx);
    expect(removed.isError, isFalse);

    final bad = await tool.run({'action': 'wat'}, ctx);
    expect(bad.isError, isTrue);
  });
}
