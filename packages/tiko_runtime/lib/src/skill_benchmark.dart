/// Fase 32 — EVAL-02 skill benchmark lintas task (audit 2026-11-28 §6 #8,
/// Voyager "perlu skill benchmark lintas task"): harness replay kumpulan
/// kasus berlabel skill lewat runner turn yang sudah ada (bukan registry
/// skill kedua, bukan eksekusi langsung skill) — mengukur pass-rate per
/// skill, token, dan regresi vs run sebelumnya.
///
/// Laporan dipersist ke `data/benchmarks/skill_benchmark.json` dan event
/// `eval.skill_benchmark` dipancarkan (bebas-konten). Never-raises terhadap
/// caller: kasus gagal runner dihitung sebagai gagal, bukan exception.

import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

/// Satu kasus benchmark berlabel skill.
class SkillBenchmarkCase {
  const SkillBenchmarkCase({
    required this.id,
    required this.slug,
    required this.prompt,
    this.expectedContains = const [],
    this.expectedTools = const {},
  });

  factory SkillBenchmarkCase.fromJson(Map<String, dynamic> json) =>
      SkillBenchmarkCase(
        id: json['id'] as String? ?? '',
        slug: json['skill'] as String? ?? json['slug'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        expectedContains:
            (json['expected_contains'] as List<dynamic>? ?? const [])
                .cast<String>(),
        expectedTools:
            (json['expected_tools'] as List<dynamic>? ?? const [])
                .cast<String>()
                .toSet(),
      );

  final String id;
  final String slug;
  final String prompt;
  final List<String> expectedContains;
  final Set<String> expectedTools;

  Map<String, dynamic> toJson() => {
        'id': id,
        'skill': slug,
        'prompt': prompt,
        if (expectedContains.isNotEmpty) 'expected_contains': expectedContains,
        if (expectedTools.isNotEmpty) 'expected_tools': expectedTools.toList(),
      };
}

/// Hasil satu kasus.
class SkillBenchmarkCaseResult {
  const SkillBenchmarkCaseResult({
    required this.caseId,
    required this.slug,
    required this.passed,
    this.failureReason,
    this.tokensUsed = 0,
    this.latencyMs = 0,
    this.toolNames = const [],
  });

  final String caseId;
  final String slug;
  final bool passed;
  final String? failureReason;
  final int tokensUsed;
  final int latencyMs;
  final List<String> toolNames;

  Map<String, dynamic> toJson() => {
        'id': caseId,
        'skill': slug,
        'passed': passed,
        if (failureReason != null) 'failure_reason': failureReason,
        'tokens_used': tokensUsed,
        'latency_ms': latencyMs,
        'tool_names': toolNames,
      };
}

/// Runner satu kasus: host membungkus `chatWithStatus` (atau stub uji).
typedef SkillBenchmarkRunner = Future<SkillBenchmarkTurn> Function(
  SkillBenchmarkCase c,
  SkillBenchmarkReport? previous,
);

/// Hasil turn dari runner.
class SkillBenchmarkTurn {
  const SkillBenchmarkTurn({
    required this.text,
    required this.success,
    this.tokensUsed = 0,
    this.latencyMs = 0,
    this.toolNames = const [],
  });

  final String text;
  final bool success;
  final int tokensUsed;
  final int latencyMs;
  final List<String> toolNames;
}

/// Agregat per-skill + keseluruhan, dengan regresi vs laporan sebelumnya.
class SkillBenchmarkReport {
  SkillBenchmarkReport({
    required this.runAt,
    required this.results,
    this.regressions = const [],
  });

  final DateTime runAt;
  final List<SkillBenchmarkCaseResult> results;
  final List<String> regressions;

  int get totalCases => results.length;
  int get passedCases => results.where((r) => r.passed).length;
  double get overallPassRate =>
      totalCases == 0 ? 0 : passedCases / totalCases;

  int get totalTokens => results.fold<int>(0, (n, r) => n + r.tokensUsed);

  /// Pass-rate per skill slug (urut slug untuk output deterministik).
  Map<String, double> get passRateBySkill {
    final bySkill = <String, List<SkillBenchmarkCaseResult>>{};
    for (final r in results) {
      bySkill.putIfAbsent(r.slug, () => []).add(r);
    }
    final out = <String, double>{};
    final keys = bySkill.keys.toList()..sort();
    for (final slug in keys) {
      final list = bySkill[slug]!;
      out[slug] = list.where((r) => r.passed).length / list.length;
    }
    return out;
  }

  /// Skill yang pass-rate-nya turun signifikan vs run sebelumnya
  /// (delta > [threshold]).
  List<String> regressionsVs(
    SkillBenchmarkReport previous, {
    double threshold = 0.2,
  }) {
    final out = <String>[];
    final now = passRateBySkill;
    final before = previous.passRateBySkill;
    for (final slug in now.keys) {
      final prev = before[slug];
      if (prev == null) continue;
      if (prev - now[slug]! > threshold) out.add(slug);
    }
    return out;
  }



  Map<String, dynamic> toJson() => {
        'run_at': runAt.toIso8601String(),
        'summary': {
          'total_cases': totalCases,
          'passed_cases': passedCases,
          'overall_pass_rate': overallPassRate,
          'total_tokens': totalTokens,
          'pass_rate_by_skill': passRateBySkill,
          if (regressions.isNotEmpty) 'regressions': regressions,
        },
        'results': [for (final r in results) r.toJson()],
      };

  static SkillBenchmarkReport fromJson(Map<String, dynamic> json) {
    final results = <SkillBenchmarkCaseResult>[];
    for (final r in json['results'] as List<dynamic>? ?? const []) {
      if (r is Map<String, dynamic>) {
        results.add(
          SkillBenchmarkCaseResult(
            caseId: r['id'] as String? ?? '',
            slug: r['skill'] as String? ?? '',
            passed: r['passed'] as bool? ?? false,
            failureReason: r['failure_reason'] as String?,
            tokensUsed: (r['tokens_used'] as num?)?.toInt() ?? 0,
            latencyMs: (r['latency_ms'] as num?)?.toInt() ?? 0,
            toolNames: (r['tool_names'] as List<dynamic>? ?? const [])
                .cast<String>(),
          ),
        );
      }
    }
    return SkillBenchmarkReport(
      runAt:
          DateTime.tryParse(json['run_at'] as String? ?? '') ??
              DateTime.now().toUtc(),
      results: results,
      regressions:
          (json['summary']?['regressions'] as List<dynamic>? ?? const [])
              .cast<String>(),
    );
  }
}

/// Harness skill benchmark (EVAL-02).
class SkillBenchmark {
  const SkillBenchmark();

  /// Jalankan semua kasus lewat [runner]; penilaian: turn sukses + semua
  /// [SkillBenchmarkCase.expectedContains] ada di teks (case-insensitive) +
  /// semua [SkillBenchmarkCase.expectedTools] muncul di toolNames.
  Future<SkillBenchmarkReport> run(
    List<SkillBenchmarkCase> cases,
    SkillBenchmarkRunner runner, {
    SkillBenchmarkReport? previous,
  }) async {
    final results = <SkillBenchmarkCaseResult>[];
    for (final c in cases) {
      try {
        final turn = await runner(c, previous);
        var passed = turn.success;
        String? reason;
        final lower = turn.text.toLowerCase();
        for (final phrase in c.expectedContains) {
          if (!lower.contains(phrase.toLowerCase())) {
            passed = false;
            reason = reason ?? 'teks tidak memuat: "$phrase"';
          }
        }
        for (final tool in c.expectedTools) {
          if (!turn.toolNames.contains(tool)) {
            passed = false;
            reason = reason ?? 'tool "$tool" tidak dipanggil';
          }
        }
        results.add(
          SkillBenchmarkCaseResult(
            caseId: c.id.isEmpty ? 'case-${results.length}' : c.id,
            slug: c.slug,
            passed: passed,
            failureReason: reason,
            tokensUsed: turn.tokensUsed,
            latencyMs: turn.latencyMs,
            toolNames: turn.toolNames,
          ),
        );
      } catch (e) {
        results.add(
          SkillBenchmarkCaseResult(
            caseId: c.id.isEmpty ? 'case-${results.length}' : c.id,
            slug: c.slug,
            passed: false,
            failureReason: 'runner error: $e',
          ),
        );
      }
    }
    final report = SkillBenchmarkReport(
      runAt: DateTime.now().toUtc(),
      results: results,
      regressions: <String>[],
    );
    if (previous != null) {
      report.regressions.addAll(report.regressionsVs(previous));
    }
    return report;
  }

  /// Muat kasus dari JSON (array) atau JSONL (satu objek per baris).
  List<SkillBenchmarkCase> loadCases(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return [
            for (final e in decoded)
              if (e is Map<String, dynamic>) SkillBenchmarkCase.fromJson(e),
          ];
        }
      } catch (_) {
        return const [];
      }
      return const [];
    }
    final out = <SkillBenchmarkCase>[];
    for (final line in trimmed.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map<String, dynamic>) {
          out.add(SkillBenchmarkCase.fromJson(decoded));
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Simpan laporan ke [path] (buat direktori bila perlu); gagal I/O
  /// tidak menggagalkan pemanggil (return false).
  bool saveReport(SkillBenchmarkReport report, String path) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  SkillBenchmarkReport? loadReport(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return SkillBenchmarkReport.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }
}

/// Tool `skill_benchmark` (fase 32, EVAL-02): model/operator menjalankan
/// benchmark skill lintas task. Kasus dimuat dari [defaultCasesPath] bila
/// ada, atau diberikan inline via argumen `cases` (array/JSONL string).
/// Laporan dipersist ke [reportPath] dan laporan sebelumnya dipakai sebagai
/// baseline regresi. Bounded: maks 64 kasus per run.
class SkillBenchmarkTool extends Tool {
  SkillBenchmarkTool({
    required this.runner,
    required this.defaultCasesPath,
    required this.reportPath,
  });

  final Future<SkillBenchmarkReport> Function(
    List<SkillBenchmarkCase>,
    SkillBenchmarkReport? previous,
  ) runner;
  final String defaultCasesPath;
  final String reportPath;

  static const maxCases = 64;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'skill_benchmark',
        description:
            'Jalankan benchmark skill lintas task dari kumpulan kasus '
            'berlabel skill. Tanpa argumen: muat kasus dari file kasus '
            'default. Argumen "cases": array JSON kasus {id, skill, prompt, '
            'expected_contains[], expected_tools[]}.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'cases': {
              'description': 'Array JSON kasus benchmark (opsional).',
            },
          },
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      const harness = SkillBenchmark();
      var cases = <SkillBenchmarkCase>[];
      final inline = args['cases'];
      if (inline is List) {
        cases = [
          for (final e in inline)
            if (e is Map<String, dynamic>) SkillBenchmarkCase.fromJson(e),
        ];
      } else if (inline is String && inline.trim().isNotEmpty) {
        cases = harness.loadCases(inline);
      } else {
        final f = File(defaultCasesPath);
        if (f.existsSync()) cases = harness.loadCases(f.readAsStringSync());
      }
      if (cases.isEmpty) {
        return const ToolResult(
          callId: '',
          content:
              'Tidak ada kasus benchmark. Berikan argumen "cases" atau '
              'sediakan file kasus default.',
          isError: true,
        );
      }
      if (cases.length > maxCases) cases = cases.sublist(0, maxCases);

      final previous = harness.loadReport(reportPath);
      final report = await runner(cases, previous);
      harness.saveReport(report, reportPath);
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ')
            .convert(report.toJson()),
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'skill_benchmark gagal: $e',
        isError: true,
      );
    }
  }
}
