import 'agent_loop.dart';

/// Evaluation harness (P1-6): a consistent benchmark suite for agent quality.
///
/// Eight metric families, each expressed as an [EvalKind]:
/// - taskCompletion: the turn must succeed and satisfy expectations.
/// - golden: the answer must contain (and not contain) golden phrases.
/// - toolPrecision: the expected tools must actually be called.
/// - recovery: a turn that hits a provider/tool error must still succeed.
/// - injectionResistance: a prompt-injection attempt must not leak secrets.
/// - memoryRecall: stored memory must surface in the answer.
/// - teamOverhead: token cost above a measured single-agent baseline.
/// - skillRegression: pass/fail compared against a previous report.
///
/// The harness is runner-agnostic: [EvalRunner] wraps any execution surface
/// (TikoRuntime.chatWithStatus, AgentLoop, a mock provider in tests) and
/// reports real token usage, tool traces and latency per turn.

enum EvalKind {
  taskCompletion,
  golden,
  toolPrecision,
  recovery,
  injectionResistance,
  memoryRecall,
  teamOverhead,
  skillRegression;

  String get name => switch (this) {
        taskCompletion => 'task_completion',
        golden => 'golden',
        toolPrecision => 'tool_precision',
        recovery => 'recovery',
        injectionResistance => 'injection_resistance',
        memoryRecall => 'memory_recall',
        teamOverhead => 'team_overhead',
        skillRegression => 'skill_regression',
      };

  static EvalKind fromName(String name) => switch (name) {
        'task_completion' => taskCompletion,
        'golden' => golden,
        'tool_precision' => toolPrecision,
        'recovery' => recovery,
        'injection_resistance' => injectionResistance,
        'memory_recall' => memoryRecall,
        'team_overhead' => teamOverhead,
        'skill_regression' => skillRegression,
        _ => throw ArgumentError('EvalKind tidak dikenal: $name'),
      };
}

/// One benchmark scenario.
class EvalCase {
  const EvalCase({
    required this.id,
    required this.kind,
    required this.prompt,
    this.expectedContains = const [],
    this.expectedNotContains = const [],
    this.expectedTools = const {},
    this.expectSuccess = true,
    this.baselineTokens,
    this.meta = const {},
  });

  factory EvalCase.fromJson(Map<String, dynamic> json) => EvalCase(
        id: json['id'] as String,
        kind: EvalKind.fromName(json['kind'] as String),
        prompt: json['prompt'] as String? ?? '',
        expectedContains:
            (json['expected_contains'] as List<dynamic>? ?? const [])
                .cast<String>(),
        expectedNotContains:
            (json['expected_not_contains'] as List<dynamic>? ?? const [])
                .cast<String>(),
        expectedTools:
            (json['expected_tools'] as List<dynamic>? ?? const [])
                .cast<String>()
                .toSet(),
        expectSuccess: json['expect_success'] as bool? ?? true,
        baselineTokens: (json['baseline_tokens'] as num?)?.toInt(),
        meta: json['meta'] as Map<String, Object?>? ?? const {},
      );

  final String id;
  final EvalKind kind;
  final String prompt;

  /// Answer must contain every phrase (case-insensitive).
  final List<String> expectedContains;

  /// Answer must contain none of these phrases (case-insensitive).
  final List<String> expectedNotContains;

  /// Tool names that must appear in the turn's tool traces.
  final Set<String> expectedTools;

  /// Whether the turn is expected to complete successfully.
  final bool expectSuccess;

  /// Single-agent token baseline for teamOverhead cases.
  final int? baselineTokens;
  final Map<String, Object?> meta;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'prompt': prompt,
        if (expectedContains.isNotEmpty)
          'expected_contains': expectedContains,
        if (expectedNotContains.isNotEmpty)
          'expected_not_contains': expectedNotContains,
        if (expectedTools.isNotEmpty) 'expected_tools': expectedTools.toList(),
        'expect_success': expectSuccess,
        if (baselineTokens != null) 'baseline_tokens': baselineTokens,
        if (meta.isNotEmpty) 'meta': meta,
      };
}

/// Result of one agent turn as observed by the harness.
class EvalTurnResult {
  const EvalTurnResult({
    required this.text,
    required this.success,
    this.tokensUsed = 0,
    this.latencyMs = 0,
    this.toolCalls = const [],
  });

  final String text;
  final bool success;
  final int tokensUsed;
  final int latencyMs;
  final List<ToolCallTrace> toolCalls;
}

typedef EvalRunner = Future<EvalTurnResult> Function(EvalCase c);

/// Verdict for a single [EvalCase].
class EvalCaseResult {
  const EvalCaseResult({
    required this.caseId,
    required this.kind,
    required this.passed,
    this.failureReason,
    this.tokensUsed = 0,
    this.latencyMs = 0,
    this.toolNames = const [],
    this.toolErrorCount = 0,
  });

  final String caseId;
  final EvalKind kind;
  final bool passed;
  final String? failureReason;
  final int tokensUsed;
  final int latencyMs;
  final List<String> toolNames;
  final int toolErrorCount;

  Map<String, dynamic> toJson() => {
        'id': caseId,
        'kind': kind.name,
        'passed': passed,
        if (failureReason != null) 'failure_reason': failureReason,
        'tokens_used': tokensUsed,
        'latency_ms': latencyMs,
        'tool_names': toolNames,
        'tool_error_count': toolErrorCount,
      };
}

/// Aggregate report over a suite run, with JSON export for artifact storage
/// and cross-run regression comparison.
class EvalReport {
  EvalReport({
    required this.label,
    required DateTime runAt,
    required this.results,
  }) : runAt = runAt.toUtc();

  final String label;
  final DateTime runAt;
  final List<EvalCaseResult> results;

  double get taskCompletionRate => _rate(
        (r) =>
            r.kind == EvalKind.taskCompletion ||
            (r.kind == EvalKind.teamOverhead && r.passed),
      );

  double get goldenCorrectnessRate =>
      _rate((r) => r.kind == EvalKind.golden);

  /// Fraction of toolPrecision cases where every expected tool was called.
  double get toolPrecisionRate => _rate((r) => r.kind == EvalKind.toolPrecision);

  /// Tool errors across all cases / total tool calls.
  double get toolErrorRate {
    final total = results.fold<int>(0, (n, r) => n + r.toolNames.length);
    if (total == 0) return 0;
    final errors = results.fold<int>(0, (n, r) => n + r.toolErrorCount);
    return errors / total;
  }

  double get recoveryRate => _rate((r) => r.kind == EvalKind.recovery);

  double get injectionResistanceRate =>
      _rate((r) => r.kind == EvalKind.injectionResistance);

  double get memoryRecallRate => _rate((r) => r.kind == EvalKind.memoryRecall);

  int get totalTokens => results.fold<int>(0, (n, r) => n + r.tokensUsed);

  double get avgLatencyMs => results.isEmpty
      ? 0
      : results.fold<int>(0, (n, r) => n + r.latencyMs) / results.length;

  /// Average extra tokens over the per-case single-agent baseline.
  double get teamOverheadTokens {
    final overhead = <int>[];
    for (final r in results) {
      final c = _cases[r.caseId]?.baselineTokens;
      if (r.kind == EvalKind.teamOverhead && c != null) {
        overhead.add(r.tokensUsed - c);
      }
    }
    if (overhead.isEmpty) return 0;
    return overhead.fold<int>(0, (a, b) => a + b) / overhead.length;
  }

  /// Case ids that passed in [previous] but fail here.
  List<String> regressionsVs(EvalReport previous) {
    final before = {
      for (final r in previous.results) r.caseId: r.passed,
    };
    return [
      for (final r in results)
        if (before[r.caseId] == true && !r.passed) r.caseId,
    ];
  }

  final Map<String, EvalCase> _cases = {};

  double _rate(bool Function(EvalCaseResult) predicate) {
    final subset = results.where(predicate).toList();
    if (subset.isEmpty) return 0;
    return subset.where((r) => r.passed).length / subset.length;
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'run_at': runAt.toIso8601String(),
        'summary': {
          'task_completion_rate': taskCompletionRate,
          'golden_correctness_rate': goldenCorrectnessRate,
          'tool_precision_rate': toolPrecisionRate,
          'tool_error_rate': toolErrorRate,
          'recovery_rate': recoveryRate,
          'injection_resistance_rate': injectionResistanceRate,
          'memory_recall_rate': memoryRecallRate,
          'total_tokens': totalTokens,
          'avg_latency_ms': avgLatencyMs,
          'team_overhead_tokens': teamOverheadTokens,
        },
        'results': [for (final r in results) r.toJson()],
      };
}

/// Runs a suite of [EvalCase]s through [runner] and aggregates the report.
class EvalHarness {
  const EvalHarness({required this.runner});

  final EvalRunner runner;

  Future<EvalReport> run(
    List<EvalCase> cases, {
    String label = 'eval',
  }) async {
    final results = <EvalCaseResult>[];
    final caseIndex = <String, EvalCase>{};
    for (final c in cases) {
      caseIndex[c.id] = c;
      final watch = Stopwatch()..start();
      EvalTurnResult turn;
      try {
        turn = await runner(c);
      } catch (e) {
        turn = const EvalTurnResult(text: '', success: false, latencyMs: 0);
      }
      watch.stop();
      results.add(_judge(c, turn, watch.elapsedMilliseconds));
    }
    final report = EvalReport(
      label: label,
      runAt: DateTime.now(),
      results: results,
    ).._cases.addAll(caseIndex);
    return report;
  }

  EvalCaseResult _judge(EvalCase c, EvalTurnResult turn, int latencyMs) {
    final toolNames = [for (final t in turn.toolCalls) t.name];
    final toolErrorCount =
        turn.toolCalls.where((t) => t.isError).length;
    final lowered = turn.text.toLowerCase();

    String? reason;
    if (c.expectSuccess && !turn.success) {
      reason = 'turn tidak sukses';
    } else {
      for (final phrase in c.expectedContains) {
        if (!lowered.contains(phrase.toLowerCase())) {
          reason = 'jawaban tidak memuat "$phrase"';
          break;
        }
      }
      if (reason == null) {
        for (final phrase in c.expectedNotContains) {
          if (lowered.contains(phrase.toLowerCase())) {
            reason = 'jawaban membocorkan "$phrase"';
            break;
          }
        }
      }
      if (reason == null && c.expectedTools.isNotEmpty) {
        final missing = c.expectedTools.difference(toolNames.toSet());
        if (missing.isNotEmpty) {
          reason = 'tool tidak dipanggil: ${missing.join(', ')}';
        }
      }
      if (reason == null && c.kind == EvalKind.teamOverhead) {
        final baseline = c.baselineTokens;
        if (baseline != null && turn.tokensUsed > baseline * 4) {
          reason = 'overhead koordinasi > 4x baseline';
        }
      }
    }

    return EvalCaseResult(
      caseId: c.id,
      kind: c.kind,
      passed: reason == null,
      failureReason: reason,
      tokensUsed: turn.tokensUsed,
      latencyMs: latencyMs,
      toolNames: toolNames,
      toolErrorCount: toolErrorCount,
    );
  }
}
