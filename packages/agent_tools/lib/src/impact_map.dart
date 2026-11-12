import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';

/// impact_map (NEW-05): peta aset yang terdampak sebuah rencana
/// SEBELUM eksekusi. Read-only — hanya memeriksa status tiap target:
/// sudah ada / masih baru / di luar workspace, plus peringatan bila
/// ada target yang sama disentuh lebih dari sekali.
class ImpactMapTool implements Tool {
  const ImpactMapTool();

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'impact_map',
    description:
        'Peta aset yang terdampak rencana: untuk tiap langkah, status '
        'targetnya (file ada / baru / di luar workspace) tanpa mengubah '
        'apa pun. Read-only.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'description': 'Langkah rencana (maks 50): {action, target}.',
        },
      },
      'required': ['steps'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final raw = args['steps'];
    if (raw is! List) {
      return const ToolResult(
        callId: '',
        content: 'steps wajib array',
        isError: true,
      );
    }
    if (raw.isEmpty || raw.length > 50) {
      return const ToolResult(
        callId: '',
        content: 'steps wajib 1-50 langkah',
        isError: true,
      );
    }
    final seen = <String, int>{};
    final lines = <String>[];
    var existing = 0, fresh = 0, outside = 0;
    for (var i = 0; i < raw.length; i++) {
      final step = raw[i];
      if (step is! Map) {
        return const ToolResult(
          callId: '',
          content: 'setiap langkah wajib objek',
          isError: true,
        );
      }
      final action = (step['action'] as String?)?.trim() ?? '';
      final target = (step['target'] as String?)?.trim() ?? '';
      if (action.isEmpty || action.length > 40) {
        return const ToolResult(
          callId: '',
          content: 'action wajib 1-40 karakter',
          isError: true,
        );
      }
      if (target.isEmpty) {
        return const ToolResult(
          callId: '',
          content: 'target wajib diisi',
          isError: true,
        );
      }
      seen[target] = (seen[target] ?? 0) + 1;
      final resolved = PathSafety.resolveInRoot(ctx.workspacePath, target);
      if (resolved == null) {
        outside++;
        lines.add('${i + 1}. $action → $target: DI LUAR WORKSPACE');
        continue;
      }
      final t = FileSystemEntity.typeSync(resolved, followLinks: true);
      if (t == FileSystemEntityType.notFound) {
        fresh++;
        lines.add('${i + 1}. $action → $target: baru (belum ada)');
      } else if (t == FileSystemEntityType.directory) {
        existing++;
        var files = 0, bytes = 0;
        for (final e in Directory(resolved).listSync(recursive: true)) {
          if (e is File) {
            files++;
            bytes += e.lengthSync();
          }
        }
        lines.add(
          '${i + 1}. $action → $target: direktori ada '
          '($files file, $bytes byte)',
        );
      } else {
        existing++;
        final size = File(resolved).lengthSync();
        lines.add('${i + 1}. $action → $target: file ada ($size byte)');
      }
    }
    lines.add(
      'Ringkasan: $existing sudah ada, $fresh baru, $outside di luar '
      'workspace',
    );
    for (final e in seen.entries) {
      if (e.value > 1) {
        lines.add('PERINGATAN: ${e.key} disentuh ${e.value} kali');
      }
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
