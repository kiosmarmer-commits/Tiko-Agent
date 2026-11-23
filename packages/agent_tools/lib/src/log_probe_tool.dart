import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// F3 (docs/15 §4) — probe log runtime: aksi `list`/`tail`/`grep` terhadap
/// berkas log di `logsDir` runtime + `runs` (ringkasan run terakhir dari
/// TurnInspector bila runtime menyediakan jatuhkannya). Read-only,
/// fail-closed: path dijail ke [logsDir] via PathSafety (symlink-aware),
/// output dibatasi, tanpa eksekusi.
class LogProbeTool implements Tool {
  LogProbeTool({
    required String logsDir,
    this.recentRuns,
    this.maxFileBytes = 5 * 1024 * 1024,
  }) : logsDir = Directory(logsDir);

  final Directory logsDir;
  final String Function()? recentRuns;
  final int maxFileBytes;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'log_probe',
        description:
            'Probe log runtime (read-only). Aksi: list (daftar berkas log) | '
            'tail (baris terakhir) | grep (cari teks) | runs (ringkasan run '
            'terakhir dari TurnInspector).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'sub': {
              'type': 'string',
              'enum': ['list', 'tail', 'grep', 'runs'],
              'description': 'Default tail.',
            },
            'file': {
              'type': 'string',
              'description':
                  'Nama berkas log relatif logsDir (opsional; default berkas '
                  '.log terbaru).',
            },
            'query': {'type': 'string', 'description': 'Teks untuk aksi grep.'},
            'lines': {
              'type': 'integer',
              'description': 'Baris untuk tail (default 40, maks 200).',
            },
          },
        },
        risk: 'low',
        parallelSafe: true,
        timeoutSec: 15,
        maxOutputChars: 12000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final sub = ((args['sub'] as String?) ?? 'tail').trim();
    switch (sub) {
      case 'list':
        return _list(sub);
      case 'tail':
        return _tailLines(args);
      case 'grep':
        return _grep(args);
      case 'runs':
        final fn = recentRuns;
        if (fn == null) {
          return const ToolResult(
            callId: '',
            content: 'runs tidak tersedia di runtime ini',
            isError: true,
          );
        }
        final out = fn();
        return ToolResult(
          callId: '',
          content: out.isEmpty ? '(belum ada run terekam)' : out,
        );
      default:
        return ToolResult(
          callId: '',
          content: 'sub tidak dikenal: $sub',
          isError: true,
        );
    }
  }

  ToolResult _list(String sub) {
    if (!logsDir.existsSync()) {
      return const ToolResult(callId: '', content: '(logsDir tidak ada)');
    }
    final entries = <String>[];
    try {
      final files = logsDir
          .listSync(followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        entries.add('${p.basename(f.path)} (${f.lengthSync()} bytes)');
      }
    } on FileSystemException {
      return const ToolResult(callId: '', content: 'gagal membaca logsDir', isError: true);
    }
    return ToolResult(
      callId: '',
      content: entries.isEmpty ? '(tidak ada berkas log)' : entries.join('\n'),
    );
  }

  Future<ToolResult> _tailLines(Map<String, dynamic> args) async {
    var lines = (args['lines'] as num?)?.toInt() ?? 40;
    if (lines < 1) lines = 1;
    if (lines > 200) lines = 200;
    final target = _resolveTarget(args);
    if (target == null) return _gagalTarget();
    try {
      final allLines = await target.readAsLines();
      final out = allLines.length <= lines
          ? allLines
          : allLines.sublist(allLines.length - lines);
      if (out.isEmpty) return const ToolResult(callId: '', content: '(log kosong)');
      return ToolResult(
        callId: '',
        content: out.map((l) => _cut(l, 240)).join('\n'),
      );
    } on FileSystemException {
      return const ToolResult(callId: '', content: 'gagal membaca berkas log', isError: true);
    }
  }

  Future<ToolResult> _grep(Map<String, dynamic> args) async {
    final query = ((args['query'] as String?) ?? '').trim();
    if (query.isEmpty) {
      return const ToolResult(callId: '', content: 'query wajib untuk aksi grep', isError: true);
    }
    if (query.length > 200) {
      return const ToolResult(callId: '', content: 'query maksimal 200 char', isError: true);
    }
    final target = _resolveTarget(args);
    if (target == null) return _gagalTarget();
    final needle = query.toLowerCase();
    final out = <String>[];
    try {
      final lines = await target.readAsLines();
      for (var i = 0; i < lines.length && out.length < 40; i++) {
        if (lines[i].toLowerCase().contains(needle)) {
          out.add('${i + 1}: ${_cut(lines[i], 240)}');
        }
      }
    } on FileSystemException {
      return const ToolResult(callId: '', content: 'gagal membaca berkas log', isError: true);
    }
    return ToolResult(
      callId: '',
      content: out.isEmpty ? '(tidak ada kecocokan)' : out.join('\n'),
    );
  }

  File? _resolveTarget(Map<String, dynamic> args) {
    final rel = (args['file'] as String?)?.trim() ?? '';
    if (!logsDir.existsSync()) return null;
    if (rel.isEmpty) {
      final files = logsDir.listSync(followLinks: false).whereType<File>().where(
            (f) => f.path.toLowerCase().endsWith('.log'),
          );
      File? newest;
      DateTime? newestTime;
      for (final f in files) {
        final t = f.statSync().modified;
        if (newestTime == null || t.isAfter(newestTime)) {
          newest = f;
          newestTime = t;
        }
      }
      return newest;
    }
    final resolved = PathSafety.resolveInRoot(logsDir.path, rel);
    if (resolved == null) return null;
    final f = File(resolved);
    if (!f.existsSync() || f.lengthSync() > maxFileBytes) return null;
    return f;
  }

  ToolResult _gagalTarget() => const ToolResult(
        callId: '',
        content: 'berkas log tidak ditemukan / di luar logsDir / terlalu besar',
        isError: true,
      );

  static String _cut(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
