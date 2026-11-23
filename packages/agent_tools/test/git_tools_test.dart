import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

Future<void> git(String cwd, List<String> argv) async {
  final r = await Process.run(
    'git',
    ['-C', cwd, ...argv],
    runInShell: false,
  );
  if (r.exitCode != 0) {
    fail('git ${argv.join(" ")} gagal exit=${r.exitCode} stderr=${r.stderr} stdout=${r.stdout}');
  }
}

ToolContext ctxOf(String root) => ToolContext(
      session: Session(id: 's-git', channel: 'cli', userKey: 'u1'),
      workspacePath: root,
    );

void main() {
  late Directory root;
  late GitCommandRunner runner;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tiko_git_');
    await git(root.path, ['init', '-q']);
    await git(root.path, ['config', 'user.email', 'test@example.test']);
    await git(root.path, ['config', 'user.name', 'Tiko Test']);
    await git(root.path, ['config', 'commit.gpgsign', 'false']);
    File('${root.path}/a.txt').writeAsStringSync('satu\n');
    await git(root.path, ['add', 'a.txt']);
    await git(root.path, ['commit', '-q', '-m', 'init']);
    File('${root.path}/baru.txt').writeAsStringSync('belum dilacak\n');
    runner = GitCommandRunner(workspaceRoot: root.path);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('git_status: file belum dilacak tampil', () async {
    final tool = GitStatusTool(runner: runner);
    final res = await tool.run({}, ctxOf(root.path));
    expect(res.isError, isFalse);
    expect(res.content, contains('?? baru.txt'));
  });

  test('git_diff: stat perubahan unstaged', () async {
    File('${root.path}/a.txt').writeAsStringSync('dua\n');
    final tool = GitDiffTool(runner: runner);
    final res = await tool.run({'stat': true}, ctxOf(root.path));
    expect(res.isError, isFalse);
    expect(res.content, contains('a.txt'));
  });

  test('git_log: commit muncul setelah dibuat', () async {
    final tool = GitLogTool(runner: runner);
    final res = await tool.run({'limit': 5}, ctxOf(root.path));
    expect(res.isError, isFalse);
    expect(res.content, contains('init'));
  });

  test('git_commit: tanpa stage ditolak fail-closed', () async {
    File('${root.path}/a.txt').writeAsStringSync('tiga\n');
    final tool = GitCommitTool(runner: runner);
    final res = await tool.run({'message': 'tanpa stage'}, ctxOf(root.path));
    expect(res.isError, isTrue);
    expect(res.content, contains('tidak ada perubahan distage'));
  });

  test('git_commit: stage + commit lewat tool; pesan dilarang kontrol chars',
      () async {
    File('${root.path}/a.txt').writeAsStringSync('dua\n');
    await git(root.path, ['add', 'a.txt']);
    final tool = GitCommitTool(runner: runner);
    final bad = await tool.run({'message': 'baris\x01rusak'}, ctxOf(root.path));
    expect(bad.isError, isTrue);

    final ok = await tool.run({'message': 'feat: tulis a.txt'}, ctxOf(root.path));
    expect(ok.isError, isFalse);
    expect(ok.content, contains('commit OK'));

    final log = await GitLogTool(runner: runner).run({'limit': 3}, ctxOf(root.path));
    expect(log.content, contains('feat: tulis a.txt'));
  });

  test('git_commit: pathspec di luar workspace ditolak', () async {
    final tool = GitCommitTool(runner: runner);
    final res = await tool.run(
      {'message': 'x', 'paths': ['../../etc']},
      ctxOf(root.path),
    );
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('git_diff: pathspec traversal ditolak', () async {
    final tool = GitDiffTool(runner: runner);
    final res = await tool.run({'path': '../..'}, ctxOf(root.path));
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });
}
