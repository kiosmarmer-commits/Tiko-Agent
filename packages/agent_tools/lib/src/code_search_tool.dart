import 'dart:io';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';

/// S19-A (rekomendasi benchmark agent) — pencarian kode hybrid di workspace:
/// ranking BM25-lite atas chunk jendela baris + normalisasi token
/// camelCase/snake_case + boost definisi simbol. Pure-Dart, offline,
/// deterministik, read-only (pola `code_context`: pindai ulang tiap
/// panggilan, tanpa indeks persisten, tanpa dependensi baru).
class CodeSearchTool implements Tool {
  CodeSearchTool({
    required this.workspaceRoot,
    this.maxFiles = 1500,
    this.maxFileSize = 256 * 1024,
    this.chunkLines = 24,
    this.chunkOverlap = 8,
  });

  final String workspaceRoot;
  final int maxFiles;
  final int maxFileSize;
  final int chunkLines;
  final int chunkOverlap;

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

  /// S22 — diekspos agar SemanticCodeIndexer memakai definisi sama
  /// (junk dir + ekstensi kode + regex definisi) sebagai BM25 dasarnya.
  static const Set<String> junkDirs = _junkDirs;
  static const Set<String> codeExts = _codeExts;
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
    '.cpp',
    '.c',
    '.h',
    '.rb',
    '.php',
  };

  static final RegExp definitionPattern = RegExp(
    r'^\s*(?:abstract\s+)?(?:class|mixin|enum|extension)\s+[a-zA-Z]|^\s*def\s+[a-zA-Z]|^\s*(?:async\s+)?function\s+[a-zA-Z]',
  );

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'code_search',
        description:
            'Pencarian kode hybrid di workspace: ranking relevansi (BM25 atas '
            'jendela baris + normalisasi camelCase/snake_case + boost '
            'definisi simbol). Read-only. Dipakai untuk menjawab "di mana X '
            'dibuat/dipakai" tanpa membaca seluruh file.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Kata kunci/frasa, mis. "payment gateway retry"',
            },
            'path': {
              'type': 'string',
              'description': 'Batasi pindai ke subdirektori (default ".")',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maksimum hasil (default 10, maks 30).',
            },
          },
          'required': ['query'],
        },
        risk: 'low',
        parallelSafe: true,
        timeoutSec: 60,
        maxOutputChars: 20000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty || query.length > 256) {
      return const ToolResult(
        callId: '',
        content: 'error: query wajib diisi (1..256 karakter)',
        isError: true,
      );
    }
    final rel = (args['path'] as String?)?.trim() ?? '.';
    var limit = (args['limit'] as num?)?.toInt() ?? 10;
    if (limit < 1) limit = 1;
    if (limit > 30) limit = 30;

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

    final queryTerms = termsOf(query);
    if (queryTerms.isEmpty) {
      return ToolResult(
        callId: '',
        content: 'tidak ada istilah valid di query "$query"',
        isError: true,
      );
    }

    final files = _collectFiles(resolved.path);
    final chunks = <_Chunk>[];
    for (final f in files) {
      chunks.addAll(_chunksOf(f, queryTerms));
    }
    if (chunks.isEmpty) {
      return ToolResult(
        callId: '',
        content: 'tidak ada file kode untuk query "$query"',
      );
    }

    final df = <String, int>{};
    for (final c in chunks) {
      for (final t in c.terms.toSet()) {
        df[t] = (df[t] ?? 0) + 1;
      }
    }
    final n = chunks.length;
    double idf(String t) => math.log(1 + n / (1 + (df[t] ?? 0)));

    final scored = <(_Chunk, double)>[];
    for (final c in chunks) {
      final tf = <String, int>{};
      for (final t in c.terms) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      var score = 0.0;
      var matched = 0;
      for (final q in queryTerms) {
        final t = tf[q];
        if (t == null) continue;
        matched++;
        score += (1 + math.log(1 + t)) * idf(q);
      }
      if (score <= 0) continue;
      score *= 1 + 0.15 * (matched / queryTerms.length);
      if (c.hasDefinitionHit) score *= 1.5;
      scored.add((c, score));
    }

    if (scored.isEmpty) {
      return ToolResult(
        callId: '',
        content: 'tidak ada hasil untuk query "$query"',
      );
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      final byPath = a.$1.relPath.compareTo(b.$1.relPath);
      if (byPath != 0) return byPath;
      return a.$1.start.compareTo(b.$1.start);
    });

    final buffer = StringBuffer(
        'code_search: "$query" -> ${scored.length.clamp(0, limit)} hasil '
        '(dari ${chunks.length} chunk/${files.length} file)\n');
    for (final (c, score) in scored.take(limit)) {
      buffer.writeln(
          '${c.relPath}:${c.start}-${c.end} (skor ${(score * 100).round() / 100})');
      for (final line in c.snippet.take(3)) {
        buffer.writeln('  ${cap(line, 160)}');
      }
      buffer.writeln('  ---');
    }
    return ToolResult(callId: '', content: buffer.toString().trim());
  }

  static String cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// camelCase/snake_case split + lowercase; token asli ( konkatenasi)
  /// tetap dimasukkan agar "PaymentGateway" cocok dengan "paymentgateway".
  static Set<String> termsOf(String input) {
    final out = <String>{};
    final raw = input
        .split(RegExp(r'[^a-zA-Z0-9_]+'))
        .where((t) => t.isNotEmpty && t != '_');
    for (final rawToken in raw) {
      final token = rawToken.toLowerCase();
      out.add(token);
      final parts = <String>[];
      final boundary = RegExp(r'[a-z0-9][A-Z]');
      var start = 0;
      for (var i = 1; i < rawToken.length; i++) {
        if (boundary.hasMatch(rawToken.substring(i - 1, i + 1))) {
          parts.add(rawToken.substring(start, i));
          start = i;
        }
      }
      parts.add(rawToken.substring(start));
      for (final part in parts.expand((x) => x.split('_'))) {
        final lowered = part.toLowerCase();
        if (lowered.length >= 2) out.add(lowered);
      }
    }
    return out;
  }

  List<_Chunk> _chunksOf(String filePath, Set<String> queryTerms) {
    final out = <_Chunk>[];
    final relPath = p.relative(filePath, from: workspaceRoot);
    try {
      final lines = File(filePath).readAsLinesSync();
      if (chunkLines <= chunkOverlap) return const [];
      var start = 0;
      while (start < lines.length) {
        final end = (start + chunkLines > lines.length)
            ? lines.length
            : start + chunkLines;
        final slice = lines.sublist(start, end);
        final terms = <String>{};
        var hasDefinitionHit = false;
        for (final line in slice) {
          terms.addAll(termsOf(line));
          if (!hasDefinitionHit && definitionPattern.hasMatch(line)) {
            hasDefinitionHit = true;
          }
        }
        if (terms.any(queryTerms.contains)) {
          out.add(_Chunk(
            relPath: relPath,
            start: start + 1,
            end: end,
            terms: terms,
            hasDefinitionHit: hasDefinitionHit,
            snippet: slice
                .map((l) => l.trim())
                .where((l) => l.isNotEmpty)
                .take(3)
                .toList(),
          ));
        }
        final next = end - chunkOverlap;
        if (next <= start || end >= lines.length) break;
        start = next;
      }
    } on FileSystemException {
      return const [];
    }
    return out;
  }

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
}

class _Chunk {
  const _Chunk({
    required this.relPath,
    required this.start,
    required this.end,
    required this.terms,
    required this.hasDefinitionHit,
    required this.snippet,
  });

  final String relPath;
  final int start;
  final int end;
  final Set<String> terms;
  final bool hasDefinitionHit;
  final List<String> snippet;
}
