import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';

/// effect_preview (NEW-02): pratinjau dampak tulis/hapus SEBELUM
/// tool write/delete benar-benar dijalankan. Read-only — file tidak
/// pernah diubah, sehingga aman dipanggil kapan pun termasuk saat
/// menimbang opsi berisiko.
class EffectPreviewTool implements Tool {
  const EffectPreviewTool();

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'effect_preview',
    description:
        'Pratinjau dampak tulis/hapus TANPA mengeksekusinya: ukuran '
        'perubahan untuk write, isi/file yang hilang untuk delete. '
        'Read-only.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['write', 'delete'],
        },
        'path': {'type': 'string', 'description': 'Path relatif.'},
        'content': {
          'type': 'string',
          'description': 'Isi baru (untuk action write).',
        },
      },
      'required': ['action', 'path'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action'] as String? ?? '';
    final path = args['path'] as String? ?? '';
    if (action != 'write' && action != 'delete') {
      return const ToolResult(
        callId: '',
        content: 'action harus write atau delete',
        isError: true,
      );
    }
    final resolved = PathSafety.resolveInRoot(ctx.workspacePath, path);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'path di luar workspace',
        isError: true,
      );
    }
    if (action == 'write') {
      return _previewWrite(resolved, args['content']);
    }
    return _previewDelete(resolved);
  }

  ToolResult _previewWrite(String resolved, Object? content) {
    if (content is! String) {
      return const ToolResult(
        callId: '',
        content: 'content wajib string untuk action write',
        isError: true,
      );
    }
    final file = File(resolved);
    final newLines = const LineSplitter().convert(content);
    if (!file.existsSync()) {
      return ToolResult(
        callId: '',
        content: 'file baru: ${newLines.length} baris, '
            '${content.length} karakter',
      );
    }
    final old = _readFile(file);
    if (old == null) {
      return const ToolResult(
        callId: '',
        content: 'file tidak bisa dibaca sebagai UTF-8',
        isError: true,
      );
    }
    final oldLines = const LineSplitter().convert(old);
    final counts = <String, int>{};
    for (final l in oldLines) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
    final added = <String>[];
    for (final l in newLines) {
      final n = counts[l] ?? 0;
      if (n > 0) {
        counts[l] = n - 1;
      } else {
        added.add(l);
      }
    }
    final removed = <String>[];
    for (final e in counts.entries) {
      for (var i = 0; i < e.value; i++) {
        removed.add(e.key);
      }
    }
    final lines = <String>[
      'file ada: ${oldLines.length} baris → ${newLines.length} baris',
      'perubahan: +${added.length} / -${removed.length} baris',
      'ukuran: ${old.length} → ${content.length} karakter',
    ];
    if (added.isNotEmpty) {
      lines.add('contoh tambahan:');
      for (final l in added.take(10)) {
        lines.add('+ $l');
      }
    }
    if (removed.isNotEmpty) {
      lines.add('contoh yang hilang:');
      for (final l in removed.take(10)) {
        lines.add('- $l');
      }
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }

  ToolResult _previewDelete(String resolved) {
    final t = FileSystemEntity.typeSync(resolved, followLinks: true);
    if (t == FileSystemEntityType.notFound) {
      return const ToolResult(
        callId: '',
        content: 'tidak ada: target hapus tidak ditemukan',
        isError: true,
      );
    }
    if (t == FileSystemEntityType.link) {
      return const ToolResult(
        callId: '',
        content: 'link: menolak memproses symlink',
        isError: true,
      );
    }
    if (t == FileSystemEntityType.directory) {
      var files = 0, bytes = 0;
      for (final e in Directory(resolved).listSync(recursive: true)) {
        if (e is File) {
          files++;
          bytes += e.lengthSync();
        }
      }
      return ToolResult(
        callId: '',
        content: 'direktori ada: $files file, $bytes byte akan hilang',
      );
    }
    final size = File(resolved).lengthSync();
    return ToolResult(
      callId: '',
      content: 'file ada: $size byte akan hilang',
    );
  }

  String? _readFile(File f) {
    try {
      return f.readAsStringSync();
    } catch (_) {
      return null;
    }
  }
}
