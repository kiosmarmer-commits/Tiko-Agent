import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

/// Git worktree isolation (P2): one linked worktree per coding task or
/// subagent, so parallel changes never share a working directory.
///
/// All git invocations use fixed-argument `Process.run` (no shell), and task
/// ids are sanitized to `[a-z0-9-]` before being used as directory names.
class WorktreeManager {
  WorktreeManager({required this.repoRoot, String? baseDir})
      : baseDir = baseDir ?? p.join(repoRoot, '.tiko-worktrees');

  final String repoRoot;

  /// Where linked worktrees live (must be inside or beside the repo).
  final String baseDir;

  bool _isSafeTaskId(String id) => RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(id);

  String _worktreePath(String taskId) => p.join(baseDir, taskId);

  Future<(int code, String out, String err)> _git(List<String> args) async {
    final result = await Process.run(
      'git',
      ['-C', repoRoot, ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
    return (result.exitCode, (result.stdout as String).trim(), (result.stderr as String).trim());
  }

  /// Creates a linked worktree with a dedicated branch for [taskId].
  /// Returns the worktree path. Throws [StateError] when git is unavailable,
  /// the repo is dirty-unsafe, or the task already has a worktree.
  Future<String> create(String taskId, {String? baseBranch}) async {
    final id = taskId.trim().toLowerCase();
    if (!_isSafeTaskId(id)) {
      throw ArgumentError(
          'taskId harus [a-z0-9-] maksimal 64 karakter: "$taskId"');
    }
    final dir = _worktreePath(id);
    if (Directory(dir).existsSync()) {
      throw StateError('worktree untuk task "$id" sudah ada: $dir');
    }
    final branch = 'tiko/$id';
    final (code, _, err) = await _git([
      'worktree',
      'add',
      '-b',
      branch,
      dir,
      if (baseBranch != null && baseBranch.isNotEmpty) baseBranch,
    ]);
    if (code != 0) {
      throw StateError('git worktree add gagal (exit $code): $err');
    }
    return dir;
  }

  /// Lists active Tiko-managed worktrees: [{task, path, branch}].
  Future<List<Map<String, String>>> list() async {
    if (!Directory(baseDir).existsSync()) return const [];
    final result = <Map<String, String>>[];
    for (final entity in Directory(baseDir).listSync()) {
      if (entity is! Directory) continue;
      final task = p.basename(entity.path);
      if (!_isSafeTaskId(task)) continue;
      result.add({
        'task': task,
        'path': entity.path,
        'branch': 'tiko/$task',
      });
    }
    return result;
  }

  /// Removes the worktree for [taskId] (keeping the branch) and prunes stale
  /// git metadata. Returns false when the worktree does not exist.
  Future<bool> remove(String taskId) async {
    final id = taskId.trim().toLowerCase();
    if (!_isSafeTaskId(id)) return false;
    final dir = _worktreePath(id);
    if (!Directory(dir).existsSync()) return false;
    final (code, _, err) = await _git(['worktree', 'remove', '--force', dir]);
    if (code != 0) {
      throw StateError('git worktree remove gagal (exit $code): $err');
    }
    await _git(['worktree', 'prune']);
    return true;
  }
}

/// Tool surface for the model: create/list/remove per-task worktrees.
class WorktreeTool implements Tool {
  WorktreeTool(this._manager);

  final WorktreeManager _manager;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'worktree',
        description:
            'Kelola git worktree per task: create (branch tiko/<task> + '
            'direktori terisolasi), list, remove. Dipakai agar perubahan '
            'paralel tidak saling menimpa di working directory yang sama.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['create', 'list', 'remove'],
            },
            'task': {
              'type': 'string',
              'description': 'Id task [a-z0-9-] (wajib untuk create/remove)',
            },
            'base_branch': {
              'type': 'string',
              'description': 'Branch dasar untuk create (opsional)',
            },
          },
          'required': ['action'],
        },
        risk: 'medium',
        timeoutSec: 90,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action']?.toString() ?? '';
    try {
      switch (action) {
        case 'create':
          final task = args['task']?.toString() ?? '';
          final path = await _manager.create(
            task,
            baseBranch: args['base_branch']?.toString(),
          );
          return ToolResult(
            callId: '',
            content: 'Worktree siap: $path (branch tiko/${task.trim().toLowerCase()})',
          );
        case 'list':
          final items = await _manager.list();
          return ToolResult(
            callId: '',
            content: items.isEmpty
                ? '(belum ada worktree)'
                : const JsonEncoder.withIndent('  ')
                    .convert([for (final i in items) i]),
          );
        case 'remove':
          final task = args['task']?.toString() ?? '';
          final removed = await _manager.remove(task);
          return ToolResult(
            callId: '',
            content: removed
                ? 'Worktree "${task.trim().toLowerCase()}" dihapus.'
                : 'Worktree "${task.trim().toLowerCase()}" tidak ditemukan.',
            isError: !removed,
          );
        default:
          return const ToolResult(
            callId: '',
            content: 'action harus create|list|remove',
            isError: true,
          );
      }
    } on ArgumentError catch (e) {
      return ToolResult(callId: '', content: e.message?.toString() ?? '$e', isError: true);
    } on StateError catch (e) {
      return ToolResult(callId: '', content: e.message, isError: true);
    }
  }
}
