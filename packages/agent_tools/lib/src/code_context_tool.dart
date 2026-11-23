import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// F2 (docs/15 §3) — repo map + pencarian simbol tanpa dependensi LSP.
/// Parser regex sederhana per bahasa (class/mixin/enum/extension + top-level
/// function Dart; def/class Python; function/class JS-TS) di atas workspace;
/// `find` = definisi, `refs` = referensi word-boundary. Read-only, stateless
/// (pindai ulang tiap panggilan agar selalu segar), guard batas file/ukuran.
class CodeContextTool implements Tool {
  CodeContextTool({
    required this.workspaceRoot,
    this.maxFiles = 2000,
    this.maxFileSize = 256 * 1024,
  });

  final String workspaceRoot;
  final int maxFiles;
  final int maxFileSize;

  static const _junkDirs = {
    '.git',
    '.dart_tool',
    'node_modules',
    'build',
    '.idea',
    '.vscode',
    '__pycache__',
    'ephemeral',
  };
  static const _codeExts = {
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.jsx',
    '.tsx',
    '.go',
    '.rs',
    '.java',
    '.kt',
  };

  static final _symbolPatterns = [
    RegExp(r'^\s*(?:abstract\s+)?(?:class|mixin|enum|extension)\s+([_a-zA-Z$][\w$]*)'),
    RegExp(r'^[\w<>?,\s\[\]]+?\s+([_a-zA-Z$][\w$]*)\s*\([^;]*\)\s*(?:async\s*)?\{$'),
    RegExp(r'^\s*def\s+(?:async\s+)?([_a-zA-Z$][\w$]*)\s*\('),
    RegExp(r'^\s*class\s+([_a-zA-Z$][\w$]*)[\s:(]'),
    RegExp(r'^\s*(?:async\s+)?function\s+([_a-zA-Z$][\w$]*)\s*\('),
  ];

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'code_context',
        description:
            'Repo map: daftar simbol kode (class/fungsi) atau cari definisi/referensi '
            'simbol di workspace. Read-only. action: "map"|"find"|"refs".',
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'description': 'map (default) | find | refs',
            },
            'symbol': {
              'type': 'string',
              'description': 'Nama simbol untuk find/refs, mis. "AgentLoop"',
            },
            'path': {
              'type': 'string',
              'description': 'Batasi pindai ke subdirektori (default ".")',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maksimum hasil (default 20, maks 50).',
            },
          },
        },
        risk: 'low',
        parallelSafe: true,
        timeoutSec: 60,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = ((args['action'] as String?) ?? 'map').trim();
    final rel = (args['path'] as String?)?.trim() ?? '.';
    var limit = (args['limit'] as num?)?.toInt() ?? 20;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;

    final resolvedPath = PathSafety.resolveInRoot(workspaceRoot, rel);
    if (resolvedPath == null) {
      return const ToolResult(
        callId: '',
        content: 'Path di luar workspace',
        isError: true,
      );
    }
    final resolved = Directory(resolvedPath);
    if (!resolved.existsSync()) {
      return ToolResult(
        callId: '',
        content: 'Path tidak ada: $rel',
        isError: true,
      );
    }

    final files = _collectFiles(resolved.path);
    if (action == 'map') {
      final buffer = StringBuffer('repo_map: ${files.length} file kode\n');
      var hits = 0;
      for (final f in files) {
        for (final hit in _symbolsOf(f)) {
          if (hits >= limit * 4) break;
          buffer.writeln(hit);
          hits++;
        }
      }
      if (hits == 0) buffer.writeln('(tidak ada simbol ditemukan)');
      return ToolResult(callId: '', content: buffer.toString().trim());
    }

    final symbol = (args['symbol'] as String?)?.trim() ?? '';
    if (symbol.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Wajib "symbol" untuk action find/refs',
        isError: true,
      );
    }
    if (!_symbolNameOk.hasMatch(symbol)) {
      return const ToolResult(
        callId: '',
        content: 'symbol tidak valid (helar 1-128, tanpa simbol khusus)',
        isError: true,
      );
    }
    final matcher = RegExp(r'\b' + RegExp.escape(symbol) + r'\b');
    final buffer = StringBuffer();
    var count = 0;
    for (final f in files) {
      if (count >= limit) break;
      try {
        final lines = File(f).readAsLinesSync();
        for (var i = 0; i < lines.length && count < limit; i++) {
          final isDef = action == 'find' && _isDefinition(lines[i], symbol);
          final isRef = action == 'refs' && matcher.hasMatch(lines[i]);
          if (isDef || isRef) {
            final relPath = p.relative(f, from: workspaceRoot);
            buffer.writeln('$relPath:${i + 1}: ${_trim(lines[i], 160)}');
            count++;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    if (count == 0) {
      return ToolResult(
        callId: '',
        content: 'tidak ada ${action == 'find' ? 'definisi' : 'referensi'} "$symbol"',
      );
    }
    return ToolResult(callId: '', content: buffer.toString().trim());
  }

  static final _symbolNameOk = RegExp(r'^[_a-zA-Z$][\w$]{0,127}$');

  List<String> _collectFiles(String startPath) {
    final out = <String>[];
    void walk(String dirPath) {
      if (out.length >= maxFiles) return;
      final dir = Directory(dirPath);
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        if (out.length >= maxFiles) return;
        final leaf = p.basename(e.path);
        if (e is Link) continue;
        if (e is Directory) {
          if (_junkDirs.contains(leaf)) continue;
          walk(e.path);
        } else if (e is File &&
            _codeExts.contains(p.extension(leaf)) &&
            e.lengthSync() <= maxFileSize) {
          out.add(e.path);
        }
      }
    }

    walk(startPath);
    return out;
  }

  List<String> _symbolsOf(String filePath) {
    final out = <String>[];
    try {
      final lines = File(filePath).readAsLinesSync();
      final relPath = p.relative(filePath, from: workspaceRoot);
      for (var i = 0; i < lines.length; i++) {
        for (final pat in _symbolPatterns) {
          final m = pat.firstMatch(lines[i]);
          if (m != null) {
            out.add('$relPath:${i + 1}: ${_trim(lines[i], 160)}');
            break;
          }
        }
      }
    } on FileSystemException {
      return const [];
    }
    return out;
  }

  bool _isDefinition(String line, String symbol) {
    for (final pat in _symbolPatterns) {
      final m = pat.firstMatch(line);
      if (m != null && m.group(1) == symbol) return true;
    }
    return false;
  }

  static String _trim(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
