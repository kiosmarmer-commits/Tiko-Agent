import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'path_safety.dart';

import 'checkpoint.dart';

/// patch_file — replace exact snippet in a workspace file (medium risk).
///
/// FR-04: when a [WorkspaceCheckpointer] is supplied, a directory snapshot
/// is taken before the file is modified so the edit can be reverted with
/// the rollback tool. The checkpoint is best-effort: a failing snapshot
/// does not block the (still safety-checked) edit.
class PatchFileTool implements Tool {
  PatchFileTool({required this.workspaceRoot, this.checkpointer});
  final String workspaceRoot;
  final WorkspaceCheckpointer? checkpointer;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'patch_file',
    description:
        'Ganti teks tepat (old → new) di file dalam workspace. old harus '
        'unik, atau set replace_all=true untuk mengganti semua kemunculan.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'old': {'type': 'string'},
        'new': {'type': 'string'},
        'replace_all': {'type': 'boolean'},
      },
      'required': ['path', 'old', 'new'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '';
    final old = args['old'] as String? ?? '';
    final neu = args['new'] as String? ?? '';
    final replaceAll = args['replace_all'] == true;
    if (old.length > 100 * 1024 || neu.length > 100 * 1024) {
      return const ToolResult(
        callId: '',
        content: 'Patch terlalu besar (maks 100 KiB per bagian).',
        isError: true,
      );
    }
    if (rel.isEmpty || old.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'path dan old wajib',
        isError: true,
      );
    }
    final resolved = PathSafety.resolveInRoot(workspaceRoot, rel);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'path tidak valid atau di luar workspace',
        isError: true,
      );
    }
    final file = File(resolved);
    if (!await file.exists()) {
      return ToolResult(
        callId: '',
        content: 'file tidak ada: $rel',
        isError: true,
      );
    }
    final fileLength = await file.length();
    if (fileLength > 1024 * 1024) {
      return const ToolResult(
        callId: '',
        content: 'File terlalu besar untuk patch aman (maks 1 MiB).',
        isError: true,
      );
    }
    final text = await file.readAsString();
    final count = old.allMatches(text).length;
    if (count == 0) {
      return const ToolResult(
        callId: '',
        content: 'old tidak ditemukan',
        isError: true,
      );
    }
    if (count > 1 && !replaceAll) {
      return ToolResult(
        callId: '',
        content: 'old tidak unik ($count kali). Perjelas konteks '
            'atau set replace_all=true.',
        isError: true,
      );
    }
    final backupPath = PathSafety.resolveInRoot(workspaceRoot, '$rel.bak');
    if (backupPath == null) {
      return const ToolResult(
        callId: '',
        content: 'Path backup tidak aman; patch dibatalkan.',
        isError: true,
      );
    }
    final rechecked = PathSafety.resolveInRoot(workspaceRoot, rel);
    if (rechecked == null || rechecked != file.absolute.path) {
      return const ToolResult(
        callId: '',
        content: 'Path berubah saat patch; operasi dibatalkan.',
        isError: true,
      );
    }
    // FR-04: snapshot the workspace before the first mutation. Best-effort.
    String? checkpointId;
    final cp = checkpointer;
    if (cp != null) {
      try {
        checkpointId = await cp.createCheckpoint(label: 'patch:$rel');
      } catch (_) {
        checkpointId = null;
      }
    }
    await file.copy(backupPath);
    await file.writeAsString(
      replaceAll ? text.replaceAll(old, neu) : text.replaceFirst(old, neu),
    );
    final summary = replaceAll
        ? 'Patched $rel ($count penggantian)'
        : 'Patched $rel';
    final header = checkpointId == null
        ? summary
        : '$summary (checkpoint: $checkpointId)';
    return ToolResult(
      callId: '',
      content: '$header\n- ${_preview(old)}\n+ ${_preview(neu)}',
    );
  }

  /// First line of a snippet, truncated for the diff preview.
  String _preview(String snippet) {
    var line = snippet.split('\n').first;
    if (line.length > 120) line = '${line.substring(0, 120)}...';
    return line;
  }
}
