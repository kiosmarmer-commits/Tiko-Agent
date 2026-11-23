import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// F2 (docs/15 §3) — git toolset aman: argv array TANPA interpreter shell
/// (metachar mustahil dieksekusi), subcommand whitelist, pathspec tervalidasi
/// PathSafety, cwd dijail workspace, timeout + output cap. Aman di host
/// dengan maupun tanpa sandbox OS karena argv tidak pernah melewati shell.
class GitCommandRunner {
  GitCommandRunner({required this.workspaceRoot, this.timeout = const Duration(seconds: 30)});

  final String workspaceRoot;
  final Duration timeout;

  /// Null bila git gagal jalan (tidak terpasang / bukan repo) — [exitCode]
  /// null menandakan spawn error, selain itu exit code asli.
  Future<({int? exitCode, String stdout, String stderr})> run(
    List<String> argv,
  ) async {
    try {
      final result = await Process.run(
        'git',
        [
          '-C',
          workspaceRoot,
          ...argv,
        ],
        // Tanpa runInShell: argv	array, tidak ada interpretasi metachar.
        runInShell: false,
      ).timeout(timeout);
      return (
        exitCode: result.exitCode,
        stdout: result.stdout as String? ?? '',
        stderr: result.stderr as String? ?? '',
      );
    } catch (_) {
      return (exitCode: null, stdout: '', stderr: '');
    }
  }

  bool get hasGit {
    try {
      final probe = Process.runSync('git', ['-C', workspaceRoot, 'rev-parse', '--is-inside-work-tree'], runInShell: false);
      return probe.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

String _tail(String s, int max) =>
    s.length <= max ? s : '${s.substring(s.length - max)}\n\u2026[dipotong depan]';

/// `git status --porcelain=v1 -b` — read-only.
class GitStatusTool implements Tool {
  GitStatusTool({required this.runner});
  final GitCommandRunner runner;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'git_status',
        description:
            'Status repo git workspace (porcelain, branch) — read-only, tanpa shell.',
        inputSchema: {'type': 'object', 'properties': {}},
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!runner.hasGit) {
      return const ToolResult(
        callId: '',
        content: 'git tidak tersedia / bukan repo git',
        isError: true,
      );
    }
    final r = await runner.run(['status', '--porcelain=v1', '-b']);
    return ToolResult(
      callId: '',
      content: (r.stdout.trim().isEmpty ? '(bersih)' : _tail(r.stdout, 8000)) + (r.exitCode == 0 ? '' : '\ngit error: ${r.stderr.trim()}'),
      isError: r.exitCode != 0,
    );
  }
}

/// `git diff [--cached] [--stat] [-- <pathspec>]` — read-only.
class GitDiffTool implements Tool {
  GitDiffTool({required this.runner});
  final GitCommandRunner runner;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'git_diff',
        description:
            'Diff kerja repo (default --stat; staged=true untuk --cached; '
            'full=true diff penuh) — read-only, tanpa shell.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'staged': {'type': 'boolean'},
            'stat': {'type': 'boolean', 'description': 'Default true. false = diff penuh.'},
            'path': {'type': 'string', 'description': 'Path relatif workspace.'},
          },
        },
        risk: 'low',
        parallelSafe: true,
        timeoutSec: 60,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!runner.hasGit) {
      return const ToolResult(
        callId: '',
        content: 'git tidak tersedia / bukan repo git',
        isError: true,
      );
    }
    final argv = <String>[
      'diff',
      if (args['staged'] == true) '--cached',
      if (args['stat'] != false) '--stat',
    ];
    final rel = args['path'] as String?;
    if (rel != null && rel.trim().isNotEmpty) {
      final resolved = PathSafety.resolveInRoot(runner.workspaceRoot, rel.trim());
      if (resolved == null) {
        return const ToolResult(
          callId: '',
          content: 'Path di luar workspace',
          isError: true,
        );
      }
      argv..add('--')..add(p.relative(resolved, from: runner.workspaceRoot));
    }
    final r = await runner.run(argv);
    return ToolResult(
      callId: '',
      content: r.exitCode == 0
          ? (r.stdout.trim().isEmpty ? '(tidak ada perubahan)' : _tail(r.stdout, 16000))
          : 'git error: ${r.stderr.trim()}',
      isError: r.exitCode != 0,
    );
  }
}

/// `git log --oneline -n <limit> [-- <pathspec>]` — read-only.
class GitLogTool implements Tool {
  GitLogTool({required this.runner});
  final GitCommandRunner runner;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'git_log',
        description: 'Riwayat commit (oneline, default 10, maks 50).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'description': 'Default 10, maks 50.',
            },
            'path': {'type': 'string'},
          },
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!runner.hasGit) {
      return const ToolResult(
        callId: '',
        content: 'git tidak tersedia / bukan repo git',
        isError: true,
      );
    }
    var limit = (args['limit'] as num?)?.toInt() ?? 10;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    final argv = <String>['log', '--oneline', '-n', '$limit'];
    final rel = args['path'] as String?;
    if (rel != null && rel.trim().isNotEmpty) {
      final resolved = PathSafety.resolveInRoot(runner.workspaceRoot, rel.trim());
      if (resolved == null) {
        return const ToolResult(
          callId: '',
          content: 'Path di luar workspace',
          isError: true,
        );
      }
      argv..add('--')..add(p.relative(resolved, from: runner.workspaceRoot));
    }
    final r = await runner.run(argv);
    return ToolResult(
      callId: '',
      content: r.exitCode == 0
          ? (r.stdout.trim().isEmpty ? '(kosong)' : _tail(r.stdout, 8000))
          : 'git error: ${r.stderr.trim()}',
      isError: r.exitCode != 0,
    );
  }
}

final _gitControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// Fase F2 — `git commit` (risk medium): hanya commit yang SUDAH distage
/// (atau pathspec eksplisit yang meng-commit berkas tervalidasi PathSafety);
/// pesan 1-200 char tanpa karakter kontrol; tanpa `--amend`/`--force`.
class GitCommitTool implements Tool {
  GitCommitTool({required this.runner});
  final GitCommandRunner runner;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'git_commit',
        description:
            'Commit perubahan yang sudah distage (opsional pathspec relatif). '
            'Pesan wajib 1-200 char; tanpa amend/force.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string'},
            'paths': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Pathspec relatif opsional (commit hanya berkas ini).',
            },
          },
          'required': ['message'],
        },
        risk: 'medium',
        timeoutSec: 60,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!runner.hasGit) {
      return const ToolResult(
        callId: '',
        content: 'git tidak tersedia / bukan repo git',
        isError: true,
      );
    }
    final message = ((args['message'] as String?) ?? '').trim();
    if (message.isEmpty || message.length > 200 || _gitControlChars.hasMatch(message)) {
      return const ToolResult(
        callId: '',
        content: 'message wajib 1-200 char tanpa karakter kontrol',
        isError: true,
      );
    }
    final pathspec = <String>[];
    final rawPaths = args['paths'];
    if (rawPaths is List) {
      if (rawPaths.length > 20) {
        return const ToolResult(
          callId: '',
          content: 'paths maksimal 20 item',
          isError: true,
        );
      }
      for (final raw in rawPaths) {
        if (raw is! String) {
          return const ToolResult(
            callId: '',
            content: 'paths wajib array string relatif',
            isError: true,
          );
        }
        final resolved = PathSafety.resolveInRoot(runner.workspaceRoot, raw.trim());
        if (resolved == null) {
          return ToolResult(
            callId: '',
            content: 'Path di luar workspace: $raw',
            isError: true,
          );
        }
        pathspec.add(p.relative(resolved, from: runner.workspaceRoot));
      }
    } else {
      final st = await runner.run(['status', '--porcelain=v1']);
      final hasStaged = st.exitCode == 0 &&
          st.stdout
              .split('\n')
              .any((line) => line.length >= 2 && line[0] != ' ' && line[0] != '?');
      if (!hasStaged) {
        return const ToolResult(
          callId: '',
          content: 'tidak ada perubahan distage; stage dulu lewat host (area .git dijail workspace)',
          isError: true,
        );
      }
    }
    final argv = <String>['commit', '-m', message];
    if (pathspec.isNotEmpty) {
      argv..add('--')..addAll(pathspec);
    }
    final r = await runner.run(argv);
    return ToolResult(
      callId: '',
      content: r.exitCode == 0
          ? 'commit OK: ${r.stdout.trim()}'
          : 'git error: ${r.stderr.trim()}',
      isError: r.exitCode != 0,
    );
  }
}
