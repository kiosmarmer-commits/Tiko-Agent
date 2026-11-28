import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Fase 49 — SWE-agent lanjutan: pipeline issue → localize → edit → validate
/// di atas loop Fase B (`tiko fix`). Tambahan utama: stage `localize`
/// deterministik (pemindaian workspace berbasis token issue) sehingga turn
/// edit menerima kandidat file + snippet sebagai konteks.
///
/// Konvensi repo:
/// - Localize deterministik tanpa LLM (token match, bounded).
/// - Edit tetap lewat turn agent penuh (tool write/patch sesuai permission).
/// - Validasi argv-exec tanpa shell bila sandbox tidak ada.
/// - Default off (LLM + eksekusi); never-raises.
class SweCandidate {
  const SweCandidate({
    required this.path,
    required this.score,
    required this.snippet,
  });

  final String path;
  final int score;
  final String snippet;

  Map<String, dynamic> toJson() =>
      {'path': path, 'score': score, if (snippet.isNotEmpty) 'snippet': snippet};
}

class SweVerifyResult {
  const SweVerifyResult({
    required this.ok,
    required this.exitCode,
    required this.output,
  });

  final bool ok;
  final int exitCode;
  final String output;
}

class SweReport {
  const SweReport({
    required this.ok,
    required this.iterations,
    required this.candidates,
    required this.verifyRuns,
    required this.summary,
  });

  final bool ok;
  final int iterations;
  final List<SweCandidate> candidates;
  final List<SweVerifyResult> verifyRuns;
  final String summary;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'iterations': iterations,
        'candidates': [for (final c in candidates) c.toJson()],
        'verify_runs': [
          for (final v in verifyRuns) {'ok': v.ok, 'exit_code': v.exitCode},
        ],
        'summary': summary,
      };
}

/// Localizer deterministik: token issue → skor file di workspace.
class SweLocalizer {
  const SweLocalizer({
    this.maxFiles = 400,
    this.maxCandidates = 5,
    this.maxFileBytes = 200 * 1024,
    this.maxSnippetChars = 400,
  });

  final int maxFiles;
  final int maxCandidates;
  final int maxFileBytes;
  final int maxSnippetChars;

  static const _extensions = {
    '.dart', '.md', '.json', '.yaml', '.yml', '.ts', '.tsx', '.js', '.jsx',
    '.py', '.txt', '.xml', '.gradle', '.kt', '.java', '.go', '.rs', '.sh',
    '.toml', '.html', '.css',
  };

  static const _stopwords = {
    'yang', 'dengan', 'untuk', 'pada', 'adalah', 'dari', 'dalam', 'tidak',
    'akan', 'bisa', 'sudah', 'ada', 'ini', 'itu', 'karena', 'jika', 'saat',
    'the', 'and', 'for', 'with', 'from', 'this', 'that', 'not', 'but', 'are',
    'when', 'into', 'should', 'must', 'have', 'has', 'been', 'error', 'test',
    'tests', 'file', 'code', 'line', 'fail', 'failed', 'pass', 'passed',
  };

  static final RegExp _token = RegExp(r'[a-z_][a-z0-9_]{3,}');

  Set<String> tokensOf(String issue) {
    final raw = _token
        .allMatches(issue.toLowerCase())
        .map((m) => m.group(0)!)
        .toSet();
    return raw.difference(_stopwords);
  }

  Future<List<SweCandidate>> localize({
    required String issue,
    required String workspaceRoot,
  }) async {
    final tokens = tokensOf(issue);
    if (tokens.isEmpty) return const [];
    final root = Directory(workspaceRoot);
    if (!root.existsSync()) return const [];
    final files = <File>[];
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (files.length >= maxFiles) break;
        if (entity is! File) continue;
        final ext = entity.path.contains('.')
            ? entity.path.substring(entity.path.lastIndexOf('.'))
            : '';
        if (!_extensions.contains(ext)) continue;
        if (entity.path.contains('/.dart_tool/') ||
            entity.path.contains('/.git/') ||
            entity.path.contains('/build/')) {
          continue;
        }
        files.add(entity);
      }
    } catch (_) {
      // fail-open: hasil parsial tetap dipakai.
    }
    final scored = <(File, int, String)>[];
    for (final f in files) {
      String content;
      try {
        final len = f.lengthSync();
        if (len > maxFileBytes) continue;
        content = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      final lower = content.toLowerCase();
      var score = 0;
      for (final t in tokens) {
        if (lower.contains(t)) score += 1;
      }
      if (score > 0) scored.add((f, score, content));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      return a.$1.path.compareTo(b.$1.path);
    });
    final out = <SweCandidate>[];
    for (final (f, score, content) in scored.take(maxCandidates)) {
      out.add(SweCandidate(
        path: f.path,
        score: score,
        snippet: _bestSnippet(content, tokens),
      ));
    }
    return out;
  }

  String _bestSnippet(String content, Set<String> tokens) {
    if (content.isEmpty) return '';
    for (final line in content.split('\n')) {
      final lower = line.toLowerCase();
      for (final t in tokens) {
        if (lower.contains(t)) {
          final trimmed = line.trim();
          return trimmed.length > maxSnippetChars
              ? trimmed.substring(0, maxSnippetChars)
              : trimmed;
        }
      }
    }
    return '';
  }
}

/// Pipeline SWE penuh. Murni (callbacks injected) — host menyuntikkan turn
/// agent penuh (mis. `chatWithStatus` sesi khusus) dan verifikasi argv-exec.
class SwePipeline {
  SwePipeline({
    required this.runTurn,
    required this.verify,
    this.localizer = const SweLocalizer(),
    this.maxIterations = 3,
  }) : assert(maxIterations >= 1 && maxIterations <= 8);

  /// Satu turn agent penuh dengan prompt bebas (termasuk konteks kandidat).
  final Future<String> Function(String prompt) runTurn;

  /// Verifikasi objektif argv-exec (exit 0 = lulus).
  final Future<SweVerifyResult> Function(String command) verify;

  final SweLocalizer localizer;
  final int maxIterations;

  String _prompt(String issue, String verifyCommand, List<SweCandidate> candidates, SweVerifyResult? last) {
    final candidateText = candidates.isEmpty
        ? '(tidak ada kandidat file — telusuri sendiri di workspace)'
        : [for (final c in candidates) '- ${c.path} (skor ${c.score})'].join('\n');
    if (last == null) {
      return '''
Tugas SWE: analisa issue berikut, perbaiki akar penyebabnya di workspace.

Issue:
$issue

Kandidat file hasil localisasi deterministik:
$candidateText

Setelah analisa, setor perubahan dengan tool edit yang tersedia. Sistem
menjalankan verifikasi objektif otomatis setelah jawabanmu:
  $verifyCommand
Jangan menanya balik — kerjakan sampai lulus verifikasi.'''.trim();
    }
    var tail = last.output;
    if (tail.length > 4000) {
      tail = '${tail.substring(tail.length - 4000)}\n…[tail terpotong]';
    }
    return '''
Verifikasi iterasi GAGAL (exit ${last.exitCode}); perintah:
  $verifyCommand

Issue asli:
$issue

Kandidat file:
$candidateText

--- output verifikasi (tail) ---
$tail
--- akhir output ---

Perbaiki akar penyebab error di atas, bukan gejalanya. Setelah jawabanmu
verifikasi dijalankan lagi.'''.trim();
  }

  /// Jalankan pipeline. Tidak pernah throw.
  Future<SweReport> run({
    required String issue,
    required String verifyCommand,
    required String workspaceRoot,
    int? maxIterations,
  }) async {
    List<SweCandidate> candidates;
    try {
      candidates = await localizer.localize(
        issue: issue,
        workspaceRoot: workspaceRoot,
      );
    } catch (_) {
      candidates = const [];
    }
    final verifyRuns = <SweVerifyResult>[];
    SweVerifyResult? last;
    final iterations = (maxIterations ?? this.maxIterations).clamp(1, 8);
    for (var i = 1; i <= iterations; i++) {
      try {
        await runTurn(_prompt(issue, verifyCommand, candidates, last));
      } catch (e) {
        return SweReport(
          ok: false,
          iterations: i - 1,
          candidates: candidates,
          verifyRuns: verifyRuns,
          summary: 'turn agent gagal di iterasi $i: $e',
        );
      }
      final SweVerifyResult outcome;
      try {
        outcome = await verify(verifyCommand);
      } catch (e) {
        return SweReport(
          ok: false,
          iterations: i,
          candidates: candidates,
          verifyRuns: verifyRuns,
          summary: 'verifikasi gagal dijalankan di iterasi $i: $e',
        );
      }
      verifyRuns.add(outcome);
      last = outcome;
      if (outcome.ok) {
        return SweReport(
          ok: true,
          iterations: i,
          candidates: candidates,
          verifyRuns: verifyRuns,
          summary: 'verifikasi lulus pada iterasi $i.',
        );
      }
    }
    return SweReport(
      ok: false,
      iterations: iterations,
      candidates: candidates,
      verifyRuns: verifyRuns,
      summary:
          'verifikasi belum lulus setelah $iterations iterasi — pulihkan '
          'workspace bila perlu.',
    );
  }
}

/// Tool `swe_fix` — issue → localize → edit → validate (risk high; hanya
/// terdaftar bila config `swe:` enabled — menjalankan turn LLM + verifikasi).
class SweFixTool implements Tool {
  SweFixTool({required this.pipeline});

  final SwePipeline pipeline;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'swe_fix',
        description:
            'Pipeline SWE (issue → lokalize → edit → validate): analisa '
            'issue, perbaiki akar penyebab di workspace, validasi dengan '
            'perintah verifikasi objektif.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'issue': {
              'type': 'string',
              'description': 'Deskripsi issue/error (wajib).',
            },
            'verify': {
              'type': 'string',
              'description': 'Perintah verifikasi (exit 0 = lulus).',
            },
            'max_iterations': {
              'type': 'integer',
              'description': 'Maks iterasi fix (default 3, maks 8).',
            },
          },
          'required': ['issue', 'verify'],
        },
        risk: 'high',
        timeoutSec: 900,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final issue = '${args['issue'] ?? ''}'.trim();
    final verifyCmd = '${args['verify'] ?? ''}'.trim();
    if (issue.isEmpty || verifyCmd.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'argumen `issue` dan `verify` wajib.',
        isError: true,
      );
    }
    final maxIter = args['max_iterations'] is int
        ? (args['max_iterations'] as int).clamp(1, 8)
        : pipeline.maxIterations;
    final report = await pipeline.run(
      issue: issue,
      verifyCommand: verifyCmd,
      workspaceRoot: ctx.workspacePath,
      maxIterations: maxIter,
    );
    return ToolResult(
      callId: '',
      content: const JsonEncoder.withIndent('  ').convert(report.toJson()),
      isError: !report.ok,
    );
  }
}
