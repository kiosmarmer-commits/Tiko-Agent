// Fase F7.1 (docs/15 §8) — eval gate rilis: harness deterministik yang
// menjalankan task emas (golden) melalui `TikoRuntime.chatWithStatus`
// perangkat provider offline (mock) di CI, dengan fallback provider LLM
// asli bila offline tidak tersedia/gagal (env `TIKO_EVAL_LIVE_CONFIG`).
// Laporan berisi skor pass-rate yang dijadikan gerbang CI.

part of 'tiko_runtime.dart';

/// Satu task eval: prompt deterministik + ekspektasi objektif atas hasil
/// turn (status sukses, substring jawaban, jumlah tool call minimum).
class EvalTaskSpec {
  const EvalTaskSpec({
    required this.id,
    required this.prompt,
    this.expectSuccess = true,
    this.expectContains = const [],
    this.expectNotContains = const [],
    this.minToolCalls = 0,
    this.maxTokens = 200000,
  });

  factory EvalTaskSpec.fromJson(Map<String, dynamic> m, {int line = 0}) {
    final id = m['id']?.toString() ?? '';
    final prompt = m['prompt']?.toString() ?? '';
    if (prompt.trim().isEmpty) {
      throw FormatException(
          'eval task baris ${line + 1}: "prompt" wajib diisi');
    }
    List<String> stringList(String key) => [
          for (final v in (m[key] as List<dynamic>? ?? const <dynamic>[]))
            if (v != null) v.toString(),
        ];
    final maxTokens = m['max_tokens'];
    return EvalTaskSpec(
      id: id.trim().isEmpty ? 'task-${line + 1}' : id.trim(),
      prompt: prompt,
      expectSuccess: m['expect_success'] is bool
          ? m['expect_success'] as bool
          : true,
      expectContains: stringList('expect_contains'),
      expectNotContains: stringList('expect_not_contains'),
      minToolCalls: m['min_tool_calls'] is int && (m['min_tool_calls'] as int) >= 0
          ? m['min_tool_calls'] as int
          : 0,
      maxTokens: maxTokens is int && maxTokens > 0 ? maxTokens : 200000,
    );
  }

  final String id;
  final String prompt;
  final bool expectSuccess;
  final List<String> expectContains;
  final List<String> expectNotContains;
  final int minToolCalls;
  final int maxTokens;

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'expect_success': expectSuccess,
        'expect_contains': expectContains,
        'expect_not_contains': expectNotContains,
        'min_tool_calls': minToolCalls,
        'max_tokens': maxTokens,
      };
}

/// Parse file JSONL task eval (`{"id": "...", "prompt": "...", ...}`).
/// Baris kosong diabaikan; baris korup dilempar dengan nomor baris.
List<EvalTaskSpec> parseEvalTasksJsonl(String raw) {
  final tasks = <EvalTaskSpec>[];
  final lines = raw.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw FormatException('eval task baris ${i + 1}: JSON tidak valid');
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('eval task baris ${i + 1}: harus berupa objek');
    }
    tasks.add(EvalTaskSpec.fromJson(decoded, line: i));
  }
  return tasks;
}

/// Hasil eksekusi satu task eval (urutan + isi deterministik).
class EvalOutcome {
  const EvalOutcome({
    required this.taskId,
    required this.passed,
    required this.reasons,
    required this.success,
    required this.tokensUsed,
    required this.toolCalls,
    required this.durationMs,
  });

  final String taskId;
  final bool passed;
  final List<String> reasons;
  final bool success;
  final int tokensUsed;
  final int toolCalls;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'passed': passed,
        'reasons': reasons,
        'success': success,
        'tokens_used': tokensUsed,
        'tool_calls': toolCalls,
        'duration_ms': durationMs,
      };
}

/// Jalankan seluruh task eval secara berurutan (urutan deterministik).
/// Gagal satu task tidak menghentikan yang lain; semua hasil dikumpulkan.
/// Fail-soft: error runtime per-task dicatat sebagai kegagalan task.
Future<Map<String, dynamic>> runEvalGate(
  TikoRuntime rt,
  List<EvalTaskSpec> tasks, {
  String channel = 'eval',
  DateTime? at,
}) async {
  final entries = <EvalOutcome>[];
  for (final task in tasks) {
    final startedAt = DateTime.now();
    var success = false;
    var tokensUsed = 0;
    var toolCalls = 0;
    final reasons = <String>[];
    try {
      final result = await rt.chatWithStatus(
        task.prompt,
        sessionId: 'eval:${task.id}',
        channel: channel,
        userKey: 'eval',
      );
      success = result.success;
      tokensUsed = result.tokensUsed;
      toolCalls = result.toolCallCount;
      if (result.success != task.expectSuccess) {
        reasons.add(
            'success=${result.success} (diharapkan ${task.expectSuccess})');
      }
      if (result.tokensUsed > task.maxTokens) {
        reasons.add('tokens=${result.tokensUsed} > max ${task.maxTokens}');
      }
      if (result.toolCallCount < task.minToolCalls) {
        reasons.add(
            'tool_calls=${result.toolCallCount} < min ${task.minToolCalls}');
      }
      for (final needle in task.expectContains) {
        if (!result.text.contains(needle)) reasons.add('tidak mengandung "$needle"');
      }
      for (final needle in task.expectNotContains) {
        if (result.text.contains(needle)) reasons.add('mengandung "$needle"');
      }
    } catch (error) {
      reasons.add('exception: $error');
    }
    final duration = DateTime.now().difference(startedAt).inMilliseconds;
    entries.add(EvalOutcome(
      taskId: task.id,
      passed: reasons.isEmpty,
      reasons: reasons,
      success: success,
      tokensUsed: tokensUsed,
      toolCalls: toolCalls,
      durationMs: duration,
    ));
  }
  final passedCount = entries.where((e) => e.passed).length;
  final score =
      entries.isEmpty ? 0.0 : passedCount / entries.length * 100.0;
  return {
    'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    'channel': channel,
    'total': entries.length,
    'passed': passedCount,
    'failed': entries.length - passedCount,
    'score': score,
    'gate_passed': passedCount == entries.length && entries.isNotEmpty,
    'entries': [for (final e in entries) e.toJson()],
  };
}
