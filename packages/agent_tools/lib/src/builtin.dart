import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import 'grep.dart';
import 'ssrf.dart';
import 'web_search.dart';
import 'path_safety.dart';
import 'sandbox.dart';

import 'safe_math.dart';

/// Built-in tools for M1 (complete set for DoD).
List<Tool> createBuiltinTools({
  String? workspaceRoot,
  SsrfGuard? ssrf,
  String searxngBaseUrl = 'http://127.0.0.1:8080',
  bool enableWebSearch = true,
  SandboxRunner? sandbox,
}) {
  final root = workspaceRoot ?? Directory.current.path;
  final guard = ssrf ?? SsrfGuard();
  return [
    DatetimeTool(),
    CalcTool(),
    ListDirTool(workspaceRoot: root),
    GrepTool(workspaceRoot: root),
    ReadFileTool(workspaceRoot: root),
    WriteFileTool(workspaceRoot: root),
    ShellTool(
      sandbox:
          sandbox ?? SandboxRunner(kind: SandboxKind.none, workspacePath: root),
    ),
    WebFetchTool(ssrf: guard),
    if (enableWebSearch)
      WebSearchTool(searxngBaseUrl: searxngBaseUrl, ssrf: guard),
  ];
}

class DatetimeTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
    name: 'datetime',
    description: 'Dapatkan tanggal dan waktu saat ini dalam UTC (ISO-8601).',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(
      callId: '',
      content: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

class CalcTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
    name: 'calc',
    description: 'Evaluasi ekspresi matematika sederhana (+ - * / dan kurung).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': 'Ekspresi, mis. (2+3)*4',
        },
      },
      'required': ['expression'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final expr = (args['expression'] as String?)?.trim() ?? '';
    if (expr.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'expression kosong',
        isError: true,
      );
    }
    try {
      return ToolResult(callId: '', content: SafeMath.calculate(expr));
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'Gagal evaluasi: $e',
        isError: true,
      );
    }
  }
}

class ListDirTool implements Tool {
  ListDirTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'list_dir',
    description: 'Daftar isi direktori di dalam workspace.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Path relatif (default ".")'},
      },
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '.';
    final resolved = safeResolve(workspaceRoot, rel);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'Path di luar workspace',
        isError: true,
      );
    }
    final dir = Directory(resolved);
    if (!await dir.exists()) {
      return ToolResult(
        callId: '',
        content: 'Direktori tidak ada: $rel',
        isError: true,
      );
    }
    final lines = <String>[];
    var truncated = false;
    await for (final entry in dir.list(followLinks: false)) {
      if (lines.length >= 1000) {
        truncated = true;
        break;
      }
      final name = p.basename(entry.path);
      lines.add('${entry is Directory ? 'dir' : 'file'}\t$name');
    }
    lines.sort();
    final content = lines.isEmpty ? '(kosong)' : lines.join('\n');
    return ToolResult(
      callId: '',
      content: truncated ? '$content\n…[daftar dibatasi 1000 entri]' : content,
    );
  }
}

class ReadFileTool implements Tool {
  ReadFileTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'read_file',
    description: 'Baca isi file teks di dalam workspace (maks 100 KB).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
    risk: 'low',
    maxOutputChars: 100000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '';
    if (rel.isEmpty) {
      return const ToolResult(callId: '', content: 'path wajib', isError: true);
    }
    final resolved = safeResolve(workspaceRoot, rel);
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
    if (len > 100 * 1024) {
      return ToolResult(
        callId: '',
        content: 'File terlalu besar ($len byte)',
        isError: true,
      );
    }
    return ToolResult(callId: '', content: await file.readAsString());
  }
}

class WriteFileTool implements Tool {
  WriteFileTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'write_file',
    description:
        'Tulis/timpa file teks di workspace. Backup otomatis jika file sudah ada.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final rel = (args['path'] as String?)?.trim() ?? '';
    final content = args['content'] as String? ?? '';
    if (content.length > 1024 * 1024) {
      return const ToolResult(callId: '', content: 'Konten melebihi batas 1 MiB.', isError: true);
    }
    if (rel.isEmpty) {
      return const ToolResult(callId: '', content: 'path wajib', isError: true);
    }
    final resolved = safeResolve(workspaceRoot, rel);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'Path di luar workspace',
        isError: true,
      );
    }
    final file = File(resolved);
    final backupPath = PathSafety.resolveInRoot(workspaceRoot, '$rel.bak');
    if (backupPath == null) {
      return const ToolResult(
        callId: '',
        content: 'Path backup tidak aman; operasi dibatalkan.',
        isError: true,
      );
    }
    if (await file.exists()) {
      await file.copy(backupPath);
    }
    await file.parent.create(recursive: true);
    final rechecked = PathSafety.resolveInRoot(workspaceRoot, rel);
    if (rechecked == null || rechecked != file.absolute.path) {
      return const ToolResult(
        callId: '',
        content: 'Path berubah saat penulisan; operasi dibatalkan.',
        isError: true,
      );
    }
    await file.writeAsString(content);
    return ToolResult(
      callId: '',
      content: 'OK wrote ${content.length} chars → $rel',
    );
  }
}

/// Shell tool — high risk; allowlist enforced by PermissionGate + local checks.
class ShellTool implements Tool {
  ShellTool({this.sandbox});
  final SandboxRunner? sandbox;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'shell',
    description:
        'Jalankan perintah shell yang di-allowlist (tanpa pipe/redirect/metachar).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'cmd': {
          'type': 'string',
          'description': 'Perintah lengkap, mis. "ls -la"',
        },
      },
      'required': ['cmd'],
    },
    risk: 'high',
    timeoutSec: 15,
    maxOutputChars: 50000,
  );

  static const _metachar = [
    ';',
    '&&',
    '||',
    '|',
    '`',
    r'$(',
    '>',
    '<',
    '\n',
    '\r',
    '\t',
  ];

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cmd = (args['cmd'] as String?)?.trim() ?? '';
    if (cmd.isEmpty) {
      return const ToolResult(callId: '', content: 'cmd kosong', isError: true);
    }
    for (final m in _metachar) {
      if (cmd.contains(m)) {
        return ToolResult(
          callId: '',
          content: 'Metacharacter shell dilarang: $m',
          isError: true,
        );
      }
    }

    final parts = cmd.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      return const ToolResult(callId: '', content: 'cmd kosong', isError: true);
    }

    // Workspace jail: reject path args that escape workspace (AGD-07 sandbox light).
    final root = p.normalize(Directory(ctx.workspacePath).absolute.path);
    for (final part in parts.skip(1)) {
      if (part.startsWith('-')) continue;
      if (part.contains('..')) {
        return const ToolResult(
          callId: '',
          content: 'Path dengan .. dilarang (workspace jail)',
          isError: true,
        );
      }
      if (part.startsWith('/') ||
          part.contains(':\\') ||
          RegExp(r'^[A-Za-z]:').hasMatch(part)) {
        try {
          final resolved = p.normalize(File(part).absolute.path);
          final insideRoot = resolved == root || p.isWithin(root, resolved);
          if (!insideRoot) {
            return ToolResult(
              callId: '',
              content: 'Path di luar workspace: $part',
              isError: true,
            );
          }
        } catch (_) {}
      }
    }

    try {
      final runner =
          sandbox ?? SandboxRunner(kind: SandboxKind.none, workspacePath: root);
      final result = await runner.run(
        parts,
        timeout: const Duration(seconds: 15),
      );

      final out = StringBuffer();
      if ((result.stdout as String).isNotEmpty) out.writeln(result.stdout);
      if ((result.stderr as String).isNotEmpty) {
        out.writeln('--- stderr ---');
        out.writeln(result.stderr);
      }
      out.writeln('exit: ${result.exitCode}');
      var text = out.toString();
      if (text.length > 50000) {
        text = '${text.substring(0, 50000)}\n…[truncated]';
      }
      return ToolResult(
        callId: '',
        content: text,
        isError: result.exitCode != 0,
      );
    } catch (e) {
      return ToolResult(callId: '', content: 'shell error: $e', isError: true);
    }
  }
}

class WebFetchTool implements Tool {
  WebFetchTool({required this.ssrf, http.Client? client}) : _client = client;

  final SsrfGuard ssrf;
  final http.Client? _client;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'web_fetch',
    description:
        'Ambil halaman HTTP(S) dan kembalikan teks (maks 2 MB). Blokir IP privat.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
      },
      'required': ['url'],
    },
    risk: 'low',
    timeoutSec: 25,
    maxOutputChars: 100000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final url = (args['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) {
      return const ToolResult(callId: '', content: 'url wajib', isError: true);
    }

    final block = await ssrf.checkUrl(url);
    if (block != null) {
      return ToolResult(
        callId: '',
        content: 'SSRF blocked: $block',
        isError: true,
      );
    }

    final client = _client ?? IOClient(ssrf.pinnedHttpClient());
    try {
      // Manual redirect handling to re-check each hop.
      var current = url;
      http.Response? response;
      for (var hop = 0; hop <= ssrf.maxRedirects; hop++) {
        final blockHop = await ssrf.checkUrl(current);
        if (blockHop != null) {
          return ToolResult(
            callId: '',
            content: 'SSRF blocked on redirect: $blockHop',
            isError: true,
          );
        }
        response = await client
            .get(Uri.parse(current), headers: {'User-Agent': 'agent_dart/0.1'})
            .timeout(ssrf.timeout);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final loc = response.headers['location'];
          if (loc == null) break;
          current = Uri.parse(current).resolve(loc).toString();
          continue;
        }
        break;
      }

      if (response == null) {
        return const ToolResult(
          callId: '',
          content: 'tidak ada respons',
          isError: true,
        );
      }
      if (response.statusCode >= 400) {
        return ToolResult(
          callId: '',
          content: 'HTTP ${response.statusCode}',
          isError: true,
        );
      }
      if (response.bodyBytes.length > ssrf.maxBytes) {
        return ToolResult(
          callId: '',
          content: 'Respons terlalu besar (${response.bodyBytes.length} byte)',
          isError: true,
        );
      }

      final contentType = response.headers['content-type'] ?? '';
      var text = response.body;
      // Strip crude HTML tags for readability.
      if (contentType.contains('html')) {
        text = _stripHtml(text);
      }
      if (text.length > 100000) {
        text = '${text.substring(0, 100000)}\n…[truncated]';
      }
      return ToolResult(callId: '', content: text);
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'web_fetch error: $e',
        isError: true,
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  String _stripHtml(String html) {
    final s = html
        .replaceAll(
          RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s;
  }
}

/// Resolves [relative] under [root]; rejects traversal and symlink escape (PRD #8).
String? safeResolve(String root, String relative) =>
    PathSafety.resolveInRoot(root, relative);
