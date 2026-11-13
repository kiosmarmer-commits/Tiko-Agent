import 'dart:io';

import 'package:agent_calc/agent_calc.dart';
import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;
import 'package:path/path.dart' as p;
import 'prediksi_tool.dart';

import 'grep.dart';
import 'probe.dart';
import 'ssrf.dart';
import 'web_search.dart';
import 'path_safety.dart';
import 'sandbox.dart';
import 'readability.dart';
import 'browser_tool.dart';
import 'skill_bundle.dart';
import 'image_generation.dart';
import 'video_generation.dart';
import 'vision.dart';
import 'code_execution.dart';
import 'batch_processing.dart';
import 'api_server.dart';
import 'ide_integration.dart';

/// Built-in tools for M1 (complete set for DoD).
List<Tool> createBuiltinTools({
  String? workspaceRoot,
  SsrfGuard? ssrf,
  String searxngBaseUrl = 'http://127.0.0.1:8080',
  String? tavilyApiKey,
  bool enableWebSearch = true,
  SandboxRunner? sandbox,
  SkillRegistry? skillRegistry,
  String? falApiKey,
  String? openaiApiKey,
  ImageProvider? imageProvider,
  bool enableImageGeneration = false,
  VideoProvider? videoProvider,
  bool enableVideoGeneration = false,
  bool enableVision = false,
  bool enableContextFiles = true,
  bool enableContextReferences = true,
  bool enableCodeExecution = false,
  String? codeExecutionWorkingDirectory,
  bool enableBatchProcessing = false,
  String? batchProcessingWorkingDirectory,
  AgentLoop? agentLoop,
  bool enableApiServer = false,
  String? apiServerWorkingDirectory,
  int apiServerPort = 8080,
  String? apiServerAuthToken,
  bool enableIdeIntegration = false,
  String? ideIntegrationWorkingDirectory,
  String ideType = 'vscode',
}) {
  final root = workspaceRoot ?? Directory.current.path;
  final guard = ssrf ?? SsrfGuard();
  
  // Create skill bundle manager if skill registry is provided
  final bundleManager = skillRegistry != null
      ? SkillBundleManager(
          skillRegistry: skillRegistry,
          bundlesDirectory: p.join(root, 'bundles'),
        )
      : null;
  
  // Create context files manager
  final contextFilesManager = enableContextFiles
      ? ContextFilesManager(
          config: const ContextFilesConfig(
            enabled: true,
            searchPaths: ['.', '..'],
          ),
          workingDirectory: root,
        )
      : null;
  
  // Create context expander
  final contextExpander = enableContextReferences
      ? EnhancedContextExpander(
          workspaceRoot: root,
          contextFilesManager: contextFilesManager,
        )
      : null;
  
  return [
    ...createPrediksiTools(),
    DatetimeTool(),
    CalcTool(),
    ListDirTool(workspaceRoot: root),
    GrepTool(workspaceRoot: root),
    ProbeTool(workspaceRoot: root),
    ReadFileTool(workspaceRoot: root),
    WriteFileTool(workspaceRoot: root),
    ShellTool(
      sandbox:
          sandbox ?? SandboxRunner(kind: SandboxKind.none, workspacePath: root),
    ),
    WebFetchTool(ssrf: guard),
    BrowserTool(
      sandbox: sandbox,
      headless: true,
    ),
    if (bundleManager != null) SkillBundleTool(bundleManager),
    if (enableWebSearch)
      WebSearchTool(
        searxngBaseUrl: searxngBaseUrl,
        tavilyApiKey: tavilyApiKey,
        ssrf: guard,
      ),
    if (enableImageGeneration && imageProvider != null)
      ImageGenerationTool(
        provider: imageProvider,
        config: const ImageGenerationConfig(),
        outputDirectory: p.join(root, 'images'),
      )
    else if (enableImageGeneration && falApiKey != null)
      ImageGenerationToolFactory.create(
        provider: 'fal',
        apiKey: falApiKey,
        outputDirectory: p.join(root, 'images'),
      ),
    if (enableVideoGeneration && videoProvider != null)
      VideoGenerationTool(
        provider: videoProvider,
        outputDirectory: p.join(root, 'videos'),
      )
    else if (enableVideoGeneration && falApiKey != null)
      VideoGenerationToolFactory.create(
        provider: 'fal',
        apiKey: falApiKey,
        outputDirectory: p.join(root, 'videos'),
      ),
    if (enableVision && openaiApiKey != null)
      ...VisionToolFactory.create(
        provider: 'openai',
        apiKey: openaiApiKey,
        outputDirectory: p.join(root, 'vision_cache'),
      ),
    if (enableContextFiles && contextFilesManager != null)
      ContextFilesTool(contextFilesManager),
    if (enableContextReferences && contextExpander != null)
      ContextReferencesTool(contextExpander),
    if (enableCodeExecution)
      CodeExecutionTool(
        config: const CodeExecutionConfig(),
        sandbox: sandbox,
        workingDirectory: codeExecutionWorkingDirectory ?? root,
      ),
    if (enableBatchProcessing)
      BatchProcessingTool(
        manager: null, // Will use default manager
        agentLoop: agentLoop,
        workingDirectory: batchProcessingWorkingDirectory ?? root,
      ),
    if (enableApiServer)
      ApiServerTool(
        config: ApiServerConfig(
          enabled: true,
          host: '127.0.0.1',
          port: apiServerPort,
          authToken: apiServerAuthToken,
        ),
        agentLoop: agentLoop,
        workingDirectory: apiServerWorkingDirectory ?? root,
      ),
    if (enableIdeIntegration)
      IdeIntegrationTool(
        config: IdeIntegrationConfig(
          enabled: true,
          ideType: ideType,
          autoDetect: true,
          enableAcp: true,
        ),
        agentLoop: agentLoop,
        tools: [], // Will be populated with available tools
        workingDirectory: ideIntegrationWorkingDirectory ?? root,
      ),
  ];
}

class DatetimeTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
    name: 'datetime',
    description: 'Dapatkan tanggal dan waktu saat ini dalam UTC (ISO-8601).',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
    parallelSafe: true,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(
      callId: '',
      content: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

/// Kalkulator eksak berbasis agent_calc (CALC-ARC-04): evaluator yang
/// sama dengan direct command tiko calc (satu sumber kebenaran),
/// dijalankan lewat CalcSandbox isolate dengan timeout dapat dibatalkan.
class CalcTool implements Tool {
  CalcTool({this.limits = CalcLimits.defaults});

  final CalcLimits limits;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'calc',
    description: 'Hitung ekspresi matematika secara eksak. WAJIB dipakai '
        'untuk semua aritmetika bukan-trivial (perkalian besar, desimal, '
        'persen, pangkat, akar). Mendukung format Indonesia: '
        '1.500.000,50 ; 2 juta ; 5rb ; 15% dari 2 juta.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': 'Ekspresi, mis. (2+3)*4 atau 15% dari 2 juta',
        },
        'scale': {
          'type': 'integer',
          'description': 'Digit desimal hasil pembagian/akar (0-50).',
        },
        'rounding': {
          'type': 'string',
          'enum': ['half_even', 'half_up', 'down', 'up', 'floor', 'ceiling'],
          'description': 'Mode pembulatan (default half_even).',
        },
        'locale': {
          'type': 'string',
          'enum': ['id', 'en'],
          'description': 'Format angka input (default id).',
        },
      },
      'required': ['expression'],
    },
    risk: 'low',
    parallelSafe: true,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final expression = (args['expression'] as String?)?.trim() ?? '';
    if (expression.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'expression kosong',
        isError: true,
      );
    }
    var scale = (args['scale'] as num?)?.toInt() ?? 12;
    if (scale < 0) scale = 0;
    if (scale > 50) scale = 50;
    final roundingName = args['rounding'] as String? ?? 'half_even';
    final locale = args['locale'] as String? ?? 'id';
    final RoundingMode rounding;
    try {
      rounding = RoundingMode.fromName(roundingName);
    } on FormatException catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    }
    // Sandbox isolate (TASK-CALC-09): evaluasi dijalankan di isolate
    // terpisah dengan timeout keras limits.timeoutMs, sehingga beban
    // besar tidak pernah menggantung runtime (TASK-CALC-21 inferensi).
    final result = await const CalcSandbox().evaluate(
      expression,
      scale: scale,
      rounding: rounding,
      locale: locale,
      limits: limits,
    );
    return ToolResult(
      callId: '',
      content: result.toJsonText(),
      isError: !result.ok,
    );
  }
}

class ListDirTool implements Tool {
  ListDirTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'list_dir',
    description:
        'Daftar isi direktori di dalam workspace (paging via offset/limit).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Path relatif (default ".")'},
        'offset': {
          'type': 'integer',
          'description': 'Indeks entri mulai, 1-based (default 1).',
        },
        'limit': {
          'type': 'integer',
          'description': 'Jumlah entri maksimum (default 1000, maks 2000).',
        }
      },
    },
    risk: 'low',
    parallelSafe: true,
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
    var offset = (args['offset'] as num?)?.toInt() ?? 1;
    var limit = (args['limit'] as num?)?.toInt() ?? 1000;
    if (offset < 1) offset = 1;
    if (limit < 1) limit = 1;
    if (limit > 2000) limit = 2000;
    final all = <String>[];
    await for (final entry in dir.list(followLinks: false)) {
      final name = p.basename(entry.path);
      all.add('${entry is Directory ? 'dir' : 'file'}\t$name');
    }
    if (all.isEmpty) {
      return const ToolResult(callId: '', content: '(kosong)');
    }
    if (offset > all.length) {
      return ToolResult(
        callId: '',
        content: 'offset melebihi jumlah entri (${all.length})',
        isError: true,
      );
    }
    all.sort();
    final end = offset - 1 + limit > all.length
        ? all.length
        : offset - 1 + limit;
    final slice = all.sublist(offset - 1, end);
    final content = slice.join('\n');
    final trailer = end < all.length
        ? '\n…[entri berlanjut; gunakan offset=${end + 1}]'
        : '';
    return ToolResult(callId: '', content: '$content$trailer');
  }
}
class ReadFileTool implements Tool {
  ReadFileTool({required this.workspaceRoot});
  final String workspaceRoot;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'read_file',
    description:
        'Baca isi file teks di dalam workspace (file utuh maks 100 KB; '
        'lebih besar otomatis dipaging).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'offset': {
          'type': 'integer',
          'description': 'Baris mulai (1-based); mode rentang bila diisi.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Jumlah baris maksimum pada mode rentang (500).',
        },
      },
      'required': ['path'],
    },
    risk: 'low',
    parallelSafe: true,
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
    if (await _isBinary(file)) {
      return const ToolResult(
        callId: '',
        content: 'File biner — read_file hanya mendukung file teks',
        isError: true,
      );
    }
    final offset = (args['offset'] as num?)?.toInt();
    final limit = (args['limit'] as num?)?.toInt();
    if (offset != null || limit != null) {
      if (len > 2 * 1024 * 1024) {
        return const ToolResult(
          callId: '',
          content: 'File terlalu besar untuk mode rentang (maks 2 MB)',
          isError: true,
        );
      }
      final List<String> all;
      try {
        all = await file.readAsLines();
      } on FormatException {
        return _notUtf8;
      } on FileSystemException {
        return _notUtf8;
      }
      final start = (offset ?? 1) - 1;
      if (start < 0 || start >= all.length) {
        return ToolResult(
          callId: '',
          content: 'offset di luar jumlah baris (${all.length})',
          isError: true,
        );
      }
      var count = limit ?? 500;
      if (count < 1) count = 1;
      if (count > 2000) count = 2000;
      final end = start + count > all.length ? all.length : start + count;
      final slice = all.sublist(start, end);
      return ToolResult(
        callId: '',
        content: '${slice.join('\n')}\n[baris ${start + 1}-$end '
            'dari ${all.length}]',
      );
    }
    if (len > 100 * 1024) {
      try {
        final all = await file.readAsLines();
        const pageSize = 500;
        final end = all.length > pageSize ? pageSize : all.length;
        return ToolResult(
          callId: '',
          content: '${all.sublist(0, end).join('\n')}\n'
              '[file besar: ${all.length} baris, $len byte — '
              'dibaca baris 1-$end; lanjutkan dengan offset=${end + 1}]',
        );
      } on FormatException {
        return _notUtf8;
      } on FileSystemException {
        return _notUtf8;
      }
    }
    try {
      return ToolResult(callId: '', content: await file.readAsString());
    } on FormatException {
      return _notUtf8;
    } on FileSystemException {
      return _notUtf8;
    }
  }

  /// Deteksi biner sederhana: byte NUL di 1 KB pertama.
  Future<bool> _isBinary(File f) async {
    final raf = await f.open();
    try {
      final bytes = await raf.read(1024);
      for (final b in bytes) {
        if (b == 0) return true;
      }
      return false;
    } finally {
      await raf.close();
    }
  }

  static const _notUtf8 = ToolResult(
    callId: '',
    content: 'File bukan teks UTF-8 yang valid',
    isError: true,
  );
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

    final client = _client ?? io.IOClient(ssrf.pinnedHttpClient());
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

  /// Readability-lite extraction now lives in readability.dart.
  String _stripHtml(String html) => htmlToText(html);
}

/// Resolves [relative] under [root]; rejects traversal and symlink escape (PRD #8).
String? safeResolve(String root, String relative) =>
    PathSafety.resolveInRoot(root, relative);
