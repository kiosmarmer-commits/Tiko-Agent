import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';

/// FR-04 (Pre-Edit Directory Checkpoint): snapshots the workspace before
/// mutating operations so `/rollback` can restore a known-good state.
///
/// Snapshots are plain file copies stored under
/// `<workspace>/.tiko/checkpoints/<id>/` with a `manifest.json` — no
/// compression dependencies, safe on Termux/VPS.
///
/// Limits (tunable): per-file size cap, total file count cap, and
/// checkpoint rotation keep the snapshot store from growing unbounded.
class WorkspaceCheckpointer {
  WorkspaceCheckpointer({
    required this.workspaceRoot,
    this.maxFileBytes = 256 * 1024,
    this.maxFiles = 2000,
    this.maxCheckpoints = 10,
  });

  final String workspaceRoot;
  final int maxFileBytes;
  final int maxFiles;
  final int maxCheckpoints;

  static const _skipDirs = {
    '.git',
    '.dart_tool',
    '.tiko',
    'build',
    'node_modules',
    '.cache',
  };

  String get _storeRoot {
    final root = workspaceRoot.endsWith('/')
        ? workspaceRoot.substring(0, workspaceRoot.length - 1)
        : workspaceRoot;
    return '$root/.tiko/checkpoints';
  }

  /// Creates a snapshot and returns its id. Never throws: on total failure
  /// returns null and the caller should proceed without a checkpoint (the
  /// edit itself is still safety-checked by the tools).
  Future<String?> createCheckpoint({String? label}) async {
    final now = DateTime.now().toUtc();
    final id =
        'cp-${now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}';
    final dir = Directory('$_storeRoot/$id/files');
    final files = <Map<String, dynamic>>[];
    var copied = 0;
    var skipped = 0;

    try {
      await dir.create(recursive: true);
      final workspace = Directory(workspaceRoot);
      if (!await workspace.exists()) return null;

      await for (final entity in workspace.list(
        recursive: true,
        followLinks: false,
      )) {
        if (copied >= maxFiles) break;
        if (entity is! File) continue;
        final rel = _relativeToWorkspace(entity.path);
        if (rel == null) continue;
        if (_isSkipped(rel)) {
          skipped++;
          continue;
        }
        final len = await entity.length();
        if (len > maxFileBytes) {
          skipped++;
          continue;
        }
        final dest = PathSafety.resolveInRoot(
          '$_storeRoot/$id/files',
          rel,
        );
        if (dest == null) continue;
        await File(dest).parent.create(recursive: true);
        await entity.copy(dest);
        files.add({
          'path': rel,
          'size': len,
        });
        copied++;
      }

      final manifest = {
        'id': id,
        'label': label,
        'created_at': now.toIso8601String(),
        'workspace_root': workspaceRoot,
        'file_count': copied,
        'skipped': skipped,
        'files': files,
      };
      final mf = File('$_storeRoot/$id/manifest.json');
      await mf.writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
      await _rotate();
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Restores every file recorded in checkpoint [id]. Returns a human
  /// readable summary, or null when the checkpoint does not exist.
  Future<String?> rollback(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id)) return null;
    final mf = File('$_storeRoot/$id/manifest.json');
    if (!await mf.exists()) return null;
    Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(await mf.readAsString());
    } catch (_) {
      return 'manifest checkpoint rusak: $id';
    }
    final entries = (manifest['files'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    var restored = 0;
    final failed = <String>[];
    for (final e in entries) {
      final rel = e['path'] as String?;
      if (rel == null) continue;
      final src = PathSafety.resolveInRoot('$_storeRoot/$id/files', rel);
      final dst = PathSafety.resolveInRoot(workspaceRoot, rel);
      if (src == null || dst == null || !File(src).existsSync()) {
        failed.add(rel);
        continue;
      }
      try {
        await File(dst).parent.create(recursive: true);
        await File(src).copy(dst);
        restored++;
      } catch (_) {
        failed.add(rel);
      }
    }
    final buf = StringBuffer(
      'Rollback ke $id selesai: $restored file dipulihkan.',
    );
    if (failed.isNotEmpty) {
      buf.write(' Gagal: ${failed.take(5).join(', ')}');
      if (failed.length > 5) buf.write(' (+${failed.length - 5} lain)');
    }
    return buf.toString();
  }

  /// Lists available checkpoints, newest first.
  Future<List<Map<String, dynamic>>> list() async {
    final out = <Map<String, dynamic>>[];
    final store = Directory(_storeRoot);
    if (!await store.exists()) return out;
    await for (final d in store.list(followLinks: false)) {
      if (d is! Directory) continue;
      final mf = File('${d.path}/manifest.json');
      if (!await mf.exists()) continue;
      try {
        final m = jsonDecode(await mf.readAsString());
        if (m is Map<String, dynamic>) out.add(m);
      } catch (_) {
        // skip corrupt manifests
      }
    }
    out.sort((a, b) => (b['created_at']?.toString() ?? '')
        .compareTo(a['created_at']?.toString() ?? ''));
    return out;
  }

  Future<void> _rotate() async {
    final store = Directory(_storeRoot);
    if (!await store.exists()) return;
    final dirs = <Directory>[];
    await for (final d in store.list(followLinks: false)) {
      if (d is Directory) dirs.add(d);
    }
    if (dirs.length <= maxCheckpoints) return;
    dirs.sort((a, b) => a.path.compareTo(b.path));
    for (final d in dirs.take(dirs.length - maxCheckpoints)) {
      try {
        await d.delete(recursive: true);
      } catch (_) {
        // best-effort rotation
      }
    }
  }

  String? _relativeToWorkspace(String path) {
    final root = workspaceRoot.endsWith('/')
        ? workspaceRoot.substring(0, workspaceRoot.length - 1)
        : workspaceRoot;
    var norm = path.replaceAll('\\', '/');
    final normRoot = root.replaceAll('\\', '/');
    if (!norm.startsWith('$normRoot/')) return null;
    final rel = norm.substring(normRoot.length + 1);
    return rel.isEmpty ? null : rel;
  }

  bool _isSkipped(String rel) {
    final segs = rel.split('/');
    return segs.any(_skipDirs.contains);
  }
}

/// `/rollback` as a callable tool (high risk: it rewrites workspace files).
class RollbackTool implements Tool {
  RollbackTool({required this.checkpointer});

  final WorkspaceCheckpointer checkpointer;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'rollback_checkpoint',
        description:
            'Pulihkan workspace ke checkpoint sebelumnya. Gunakan setelah '
            'edit yang salah. Daftar checkpoint: tool list_checkpoints.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'checkpoint_id': {'type': 'string'},
          },
          'required': ['checkpoint_id'],
        },
        risk: 'high',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final id = (args['checkpoint_id'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      final cps = await checkpointer.list();
      if (cps.isEmpty) {
        return const ToolResult(
          callId: '',
          content: 'Tidak ada checkpoint tersedia.',
          isError: true,
        );
      }
      final lines = cps
          .map((m) =>
              '- ${m['id']} (${m['label'] ?? 'tanpa label'}, '
              '${m['file_count']} file, ${m['created_at']})')
              .take(10)
              .join('\n');
      return ToolResult(callId: '', content: 'Checkpoint tersedia:\n$lines');
    }
    final result = await checkpointer.rollback(id);
    if (result == null) {
      return ToolResult(
        callId: '',
        content: 'Checkpoint tidak ditemukan: $id',
        isError: true,
      );
    }
    return ToolResult(callId: '', content: result);
  }
}

/// Companion listing tool so the model can discover checkpoint ids without
/// calling the high-risk rollback tool blind.
class ListCheckpointsTool implements Tool {
  ListCheckpointsTool({required this.checkpointer});

  final WorkspaceCheckpointer checkpointer;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'list_checkpoints',
        description:
            'Daftar checkpoint workspace yang tersedia untuk rollback.',
        inputSchema: {'type': 'object', 'properties': {}},
        risk: 'low',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cps = await checkpointer.list();
    if (cps.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Belum ada checkpoint.',
      );
    }
    final lines = cps
        .map((m) =>
            '- ${m['id']} (label=${m['label'] ?? '-'}, '
            '${m['file_count']} file, ${m['created_at']})')
        .join('\n');
    return ToolResult(callId: '', content: lines);
  }
}
