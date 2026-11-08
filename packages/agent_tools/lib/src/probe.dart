import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';

/// probe — file metadata preview without loading the full content
/// (NEW-01). Returns size, line count, token estimate, type and an
/// outline so the model can decide whether and how to read the file.
class ProbeTool implements Tool {
  ProbeTool({required this.workspaceRoot});

  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'probe',
    description:
        'Pratinjau metadata file workspace tanpa memuat isi: ukuran, '
        'baris, estimasi token, tipe, dan outline. Gunakan sebelum '
        'read_file.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
    risk: 'low',
  );

  static const int _headBytes = 64 * 1024;

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '';
    if (rel.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'path wajib',
        isError: true,
      );
    }
    final resolved = PathSafety.resolveInRoot(workspaceRoot, rel);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'Path di luar workspace',
        isError: true,
      );
    }
    final file = File(resolved);
    if (!await file.exists()) {
      return ToolResult(
        callId: '',
        content: 'File tidak ada: $rel',
        isError: true,
      );
    }
    final len = await file.length();
    final raf = await file.open();
    try {
      final chunk =
          len < _headBytes ? await raf.read(len) : await raf.read(_headBytes);
      final head = const Utf8Codec(allowMalformed: true).decode(chunk);
      final truncated = len > _headBytes;
      final lines = head.isEmpty ? 0 : head.split('\n').length;
      final tokensEst = (len / 4).round();
      final dot = rel.lastIndexOf('.');
      final ext = dot < 0 ? '' : rel.substring(dot + 1).toLowerCase();
      final outline = _outline(head, ext);
      final advice = tokensEst > 4000
          ? 'File besar; baca bertahap dengan read_file offset/limit.'
          : 'Cukup kecil untuk dibaca penuh dengan read_file.';
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'path': rel,
          'type': ext.isEmpty ? 'bin' : ext,
          'size_bytes': len,
          'lines_head': lines,
          if (truncated) 'head_truncated': true,
          'tokens_est': tokensEst,
          'outline': outline,
          'advice': advice,
        }),
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'probe error: $e',
        isError: true,
      );
    } finally {
      await raf.close();
    }
  }

  List<String> _outline(String head, String ext) {
    final lines = head.split('\n');
    if (ext == 'md' || ext == 'markdown') {
      return lines
          .where((l) => RegExp(r'^#{1,6}\s+\S').hasMatch(l))
          .map((l) => l.trim())
          .take(30)
          .toList();
    }
    if (ext == 'dart') {
      final re = RegExp(
        r'^(?:abstract\s+|sealed\s+|base\s+|final\s+)*'
        r'(?:class|enum|mixin|extension)\s+\w+',
      );
      final symbols = <String>[];
      for (final l in lines) {
        if (re.hasMatch(l)) symbols.add(l.split('{').first.trim());
        if (symbols.length >= 30) break;
      }
      return symbols;
    }
    if (ext == 'csv' || ext == 'tsv') {
      final first = lines.first.trim();
      if (first.isEmpty) return const [];
      final sep = ext == 'csv' ? ',' : '\t';
      final cols = first.split(sep).map((c) => c.trim()).toList();
      return ['columns: ${cols.join(', ')}'];
    }
    return const [];
  }
}
