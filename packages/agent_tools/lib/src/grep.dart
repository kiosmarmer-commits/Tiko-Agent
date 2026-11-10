import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// grep - regex search across workspace files (read-only, low risk).
///
/// Walks the workspace, skips VCS/build directories, applies an optional
/// glob filter on the file name, and reports matches as `path:line: text`
/// with optional surrounding context lines.
class GrepTool implements Tool {
  GrepTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'grep',
    description: 'Cari pola regex di seluruh file teks workspace. '
        'Opsi: glob (mis. "*.dart"), context_lines, max_results, '
        'case_sensitive.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string'},
        'glob': {
          'type': 'string',
          'description': 'Filter nama file, mis. *.dart',
        },
        'context_lines': {
          'type': 'integer',
          'description': 'Baris konteks di sekitar cocok (default 0)',
        },
        'max_results': {
          'type': 'integer',
          'description': 'Maks baris hasil (default 50)',
        },
        'case_sensitive': {'type': 'boolean'},
      },
      'required': ['pattern'],
    },
    risk: 'low',
    parallelSafe: true,
    timeoutSec: 20,
    maxOutputChars: 50000,
  );

  static const _skipDirs = {
    '.git',
    '.dart_tool',
    'build',
    '.venv',
    'node_modules',
  };
  static const _maxFileBytes = 1024 * 1024;
  static const _maxLineChars = 200;

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = (args['pattern'] as String?)?.trim() ?? '';
    if (pattern.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'pattern wajib',
        isError: true,
      );
    }
    var contextLines = (args['context_lines'] as num?)?.toInt() ?? 0;
    if (contextLines < 0) contextLines = 0;
    var maxResults = (args['max_results'] as num?)?.toInt() ?? 50;
    if (maxResults < 1) maxResults = 1;
    if (maxResults > 500) maxResults = 500;
    final caseSensitive = (args['case_sensitive'] as bool?) ?? true;

    RegExp regex;
    try {
      regex = RegExp(pattern, caseSensitive: caseSensitive);
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'Regex tidak valid: $e',
        isError: true,
      );
    }
    final glob = (args['glob'] as String?)?.trim() ?? '';
    final globRegex = glob.isEmpty ? null : _globToRegex(glob);

    final root = PathSafety.resolveInRoot(workspaceRoot, '.');
    if (root == null) {
      return const ToolResult(
        callId: '',
        content: 'Workspace tidak valid',
        isError: true,
      );
    }

    final matches = <String>[];
    var filesScanned = 0;
    var truncated = false;
    final queue = <Directory>[Directory(root)];
    while (queue.isNotEmpty && !truncated) {
      final dir = queue.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (entry is Link) continue;
        final name = p.basename(entry.path);
        if (entry is Directory) {
          if (_skipDirs.contains(name)) continue;
          queue.add(entry);
          continue;
        }
        if (globRegex != null && !globRegex.hasMatch(name)) continue;
        final file = File(entry.path);
        String text;
        try {
          final len = file.lengthSync();
          if (len == 0 || len > _maxFileBytes) continue;
          text = file.readAsStringSync();
        } catch (_) {
          continue; // Binary or unreadable.
        }
        if (text.contains(String.fromCharCode(0))) continue;
        filesScanned++;
        final fileMatches = _matchFile(
          text,
          p.relative(entry.path, from: root),
          regex,
          contextLines,
        );
        for (final m in fileMatches) {
          if (matches.length >= maxResults) {
            truncated = true;
            break;
          }
          matches.add(m);
        }
        if (truncated) break;
      }
    }

    if (matches.isEmpty) {
      return ToolResult(
        callId: '',
        content: 'Tidak ada kecocokan ($filesScanned file dipindai).',
      );
    }
    final trailer = truncated
        ? '\n…[dipotong pada $maxResults baris; '
              'persempit pattern/glob atau naikkan max_results]'
        : '';
    return ToolResult(
      callId: '',
      content: '${matches.join('\n')}$trailer',
    );
  }

  List<String> _matchFile(
    String text,
    String relPath,
    RegExp regex,
    int contextLines,
  ) {
    final lines = text.split('\n');
    final out = <String>[];
    final shown = <int>{};
    for (var i = 0; i < lines.length; i++) {
      if (!regex.hasMatch(lines[i])) continue;
      final start = i - contextLines < 0 ? 0 : i - contextLines;
      var end = i + contextLines;
      if (end >= lines.length) end = lines.length - 1;
      for (var j = start; j <= end; j++) {
        if (shown.contains(j)) continue;
        shown.add(j);
        var line = lines[j];
        if (line.length > _maxLineChars) {
          line = '${line.substring(0, _maxLineChars)}…';
        }
        final prefix = j == i ? '' : '-';
        out.add('$prefix$relPath:${j + 1}: $line');
      }
    }
    return out;
  }

  /// Converts a simple glob ("*.dart", "test_?.dart") to a name RegExp.
  static RegExp _globToRegex(String glob) {
    final sb = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        sb.write('[^/]*');
      } else if (c == '?') {
        sb.write('[^/]');
      } else {
        sb.write(RegExp.escape(c));
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString());
  }
}
