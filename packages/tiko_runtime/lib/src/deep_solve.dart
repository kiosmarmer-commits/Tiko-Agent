/// Fase 30 — ToT/LATS bounded deep-solve (audit 2026-11-28 §6.5, "adopt
/// selectively"): planner pencarian bounded untuk task berat. BUKAN replikasi
/// penuh paper (tanpa MCTS + value-head): branching terbatas, kedalaman
/// terbatas, cap LLM-call dan wall-clock keras, dan dieksekusi lewat tool
/// `deep_solve` yang dipanggil model saat task menuntut eksplorasi — bukan
/// jalur default chat.
///
/// Algoritma (deterministik-bounded):
/// 1. *Expand*: minta [DeepSolveCfg.branching] pendekatan alternatif
///    (satu panggilan LLM); gagal parse → satu kandidat identitas.
/// 2. *Value*: tiap kandidat dinilai LLM judge `SCORE:`/`REASON:` (pola
///    SelfRewardJudge) — LATS-style value function.
/// 3. *Refine* per level: kandidat terbaik dipecah jadi varian lebih konkret;
///    ulang sampai [DeepSolveCfg.depth].
/// Semua kegagalan LLM degenerate ke hasil terbaik yang tersedia —
/// never-raises terhadap caller.

import 'dart:convert';

import 'package:agent_core/agent_core.dart';

import 'event_bus.dart';
import 'tiko_config.dart';

class DeepSolveCandidate {
  DeepSolveCandidate({
    required this.id,
    required this.level,
    required this.parentId,
    required this.approach,
    this.score = 0,
    this.reason = '',
    this.isRoot = false,
  });

  final String id;
  final int level;
  final String parentId;
  final String approach;
  double score;
  String reason;
  final bool isRoot;

  Map<String, dynamic> toJson() => {
        'id': id,
        'level': level,
        'parent_id': parentId,
        'approach': approach,
        'score': score,
        'reason': reason,
        if (isRoot) 'root': true,
      };
}

class DeepSolveResult {
  const DeepSolveResult({
    required this.task,
    required this.approach,
    required this.steps,
    required this.explored,
    required this.llmCalls,
    required this.elapsedMs,
    required this.capped,
    this.error,
  });

  final String task;
  final String approach;
  final List<String> steps;
  final List<DeepSolveCandidate> explored;

  /// Jumlah panggilan LLM yang benar-benar dilakukan.
  final int llmCalls;
  final int elapsedMs;

  /// true bila cap LLM/wall-clock memotong eksplorasi.
  final bool capped;
  final String? error;

  Map<String, dynamic> toJson() => {
        'task': task.length > 200 ? task.substring(0, 200) : task,
        'approach': approach,
        'steps': steps,
        'explored': explored.map((c) => c.toJson()).toList(),
        'llm_calls': llmCalls,
        'elapsed_ms': elapsedMs,
        'capped': capped,
        if (error != null) 'error': error,
      };
}

class DeepSolveEngine {
  DeepSolveEngine({
    required this.llmProvider,
    this.config = const DeepSolveCfg(),
    EventBus? events,
  })  : _events = events,
        assert(config.enabled, 'DeepSolveEngine hanya dibuat bila enabled');

  final LlmProvider llmProvider;
  final DeepSolveCfg config;
  final EventBus? _events;

  int _calls = 0;
  bool _capped = false;
  final List<DeepSolveCandidate> _explored = [];
  DateTime _deadline = DateTime.now();

  bool get _budgetLeft => _calls < config.maxLlmCalls && !DateTime.now().isAfter(_deadline);

  Future<DeepSolveResult> solve(String task) async {
    final started = DateTime.now();
    _deadline = started.add(Duration(seconds: config.maxWallClockSec));
    _calls = 0;
    _capped = false;
    _explored.clear();
    String? error;

    var frontier = <DeepSolveCandidate>[];
    try {
      frontier = await _expandRoot(task);
      await _judgeAll(frontier);
      for (var level = 1; level < config.depth; level++) {
        if (frontier.isEmpty || !_budgetLeft) {
          _capped = _capped || _calls >= config.maxLlmCalls;
          break;
        }
        final best = _bestOf(frontier);
        final refined = await _refine(task, best);
        await _judgeAll(refined);
        if (refined.isNotEmpty) frontier = refined;
      }
    } catch (e) {
      error = '$e';
    }

    final pool = frontier.isNotEmpty ? frontier : _explored;
    final best = pool.isNotEmpty
        ? _bestOf(pool)
        : DeepSolveCandidate(
            id: 'root',
            level: 0,
            parentId: '',
            approach: task,
            isRoot: true,
          );

    _emit('deep_solve.done', {
      'llm_calls': _calls,
      'explored': _explored.length,
      'capped': _capped,
      if (error != null) 'error': error,
    });

    return DeepSolveResult(
      task: task,
      approach: best.approach,
      steps: await _stepsOf(task, best, error != null || pool.isEmpty),
      explored: List.of(_explored),
      llmCalls: _calls,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
      capped: _capped,
      error: error,
    );
  }

  Future<List<String>> _stepsOf(
    String task,
    DeepSolveCandidate best,
    bool fallback,
  ) async {
    if (fallback || !_budgetLeft) {
      _capped = _capped || _calls >= config.maxLlmCalls;
      return _fallbackSteps(best.approach);
    }
    final text = await _ask(
      'Pecah pendekatan berikut menjadi maksimal 6 langkah konkret bernomor. '
      'Balas HANYA langkah bernomor, tanpa kalimat pembuka.\n\n'
      'Task: $task\nPendekatan: ${best.approach}',
    );
    final steps = _parseNumbered(text ?? '');
    return steps.isNotEmpty ? steps : _fallbackSteps(best.approach);
  }

  List<String> _fallbackSteps(String approach) => [
        'Jalankan pendekatan: ${approach.length > 160 ? approach.substring(0, 160) : approach}',
      ];

  Future<List<DeepSolveCandidate>> _expandRoot(String task) async {
    if (!_budgetLeft) {
      _capped = true;
      return [
        DeepSolveCandidate(
          id: 'root',
          level: 0,
          parentId: '',
          approach: task,
          isRoot: true,
        ),
      ];
    }
    final text = await _ask(
      'Untuk task berikut, hasilkan ${config.branching} pendekatan penyelesaian '
      'yang benar-benar berbeda (bukan variasi kalimat). '
      'Balas HANYA baris bernomor "1. ...", satu baris per pendekatan.\n\n'
      'Task: $task',
    );
    final lines = _parseNumbered(text ?? '');
    if (lines.isEmpty) {
      return [
        DeepSolveCandidate(
          id: 'root',
          level: 0,
          parentId: '',
          approach: task,
          isRoot: true,
        ),
      ];
    }
    var i = 0;
    return [
      for (final line in lines.take(config.branching))
        DeepSolveCandidate(
          id: 'L0-${i++}',
          level: 0,
          parentId: 'root',
          approach: line,
        ),
    ];
  }

  Future<List<DeepSolveCandidate>> _refine(
    String task,
    DeepSolveCandidate parent,
  ) async {
    if (!_budgetLeft) {
      _capped = true;
      return const [];
    }
    final text = await _ask(
      'Perdalam pendekatan berikut menjadi ${config.branching} varian eksekusi '
      'yang lebih konkret untuk task. Balas HANYA baris bernomor.\n\n'
      'Task: $task\nPendekatan: ${parent.approach}\n'
      'Catatan judge: ${parent.reason}',
    );
    final lines = _parseNumbered(text ?? '');
    if (lines.isEmpty) return const [];
    var i = 0;
    return [
      for (final line in lines.take(config.branching))
        DeepSolveCandidate(
          id: 'L${parent.level}-${i++}',
          level: parent.level + 1,
          parentId: parent.id,
          approach: line,
        ),
    ];
  }

  Future<void> _judgeAll(List<DeepSolveCandidate> candidates) async {
    for (final c in candidates) {
      if (!_budgetLeft) {
        _capped = true;
        return;
      }
      final verdict = await _judge(c);
      _explored.add(c);
      if (verdict != null) {
        final (score, reason) = verdict;
        c.score = score;
        c.reason = reason;
      } else {
        c.score = 0;
        c.reason = 'judge tidak tersedia';
      }
    }
  }

  Future<(double, String)?> _judge(DeepSolveCandidate c) async {
    final text = await _ask(
      'Nilai kelayakan pendekatan berikut untuk task (0.00-1.00). '
      'Balas tepat dua baris:\nSCORE: <angka 0.00-1.00>\nREASON: <satu kalimat>\n\n'
      'Task: ${c.isRoot ? c.approach : ''}\nPendekatan: ${c.approach}',
    );
    if (text == null) return null;
    return DeepSolveEngine.parseVerdict(text);
  }

  /// Pola SelfRewardJudge: satu request non-stream, ambil delta pertama.
  /// Return null bila gagal/limit — caller memutuskan fallback.
  Future<String?> _ask(String prompt) async {
    if (!_budgetLeft) {
      _capped = true;
      return null;
    }
    _calls++;
    try {
      final request = ChatRequest(
        messages: [
          ChatMessage(role: 'user', content: prompt),
        ],
        stream: false,
        temperature: 0.0,
        maxTokens: config.maxTokensPerCall,
      );
      final response = await llmProvider.chat(request).first;
      if (response is! LlmTextDelta) return null;
      final text = response.delta.trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  DeepSolveCandidate _bestOf(List<DeepSolveCandidate> candidates) {
    var best = candidates.first;
    for (final c in candidates.skip(1)) {
      if (c.score > best.score ||
          (c.score == best.score && c.id.compareTo(best.id) < 0)) {
        best = c;
      }
    }
    return best;
  }

  static List<String> _parseNumbered(String text) => [
        for (final raw in text.split('\n'))
          () {
            final m = RegExp(r'^\s*\d+[.)]\s*(.+)$').firstMatch(raw);
            return m?.group(1)?.trim() ?? '';
          }(),
      ].where((s) => s.isNotEmpty).toList();

  /// Pola SelfRewardJudge.parseVerdict — strict: tanpa `SCORE:` valid → null.
  static (double, String)? parseVerdict(String text) {
    final score = RegExp(r'SCORE:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
    if (score == null) return null;
    final value = double.tryParse(score.group(1)!);
    if (value == null || value < 0 || value > 1) return null;
    final reason =
        RegExp(r'REASON:\s*(.+)').firstMatch(text)?.group(1)?.trim() ?? '';
    return (value.clamp(0.0, 1.0).toDouble(), reason);
  }

  void _emit(String type, Map<String, dynamic> data) {
    try {
      _events?.emit(type, data);
    } catch (_) {}
  }
}

/// Tool `deep_solve` — model memanggilnya untuk task berat yang butuh
/// eksplorasi pendekatan (ToT/LATS bounded). Tidak mengubah permission;
/// hasil berupa rencana teks, eksekusi tetap lewat jalur tool biasa.
class DeepSolveTool extends Tool {
  DeepSolveTool(this._engine);

  final DeepSolveEngine _engine;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'deep_solve',
        description:
            'Eksplorasi beberapa pendekatan penyelesaian untuk task yang '
            'berat/berisiko (bounded tree search), lalu kembalikan pendekatan '
            'terbaik beserta langkah konkret. Gunakan untuk tugas multi-langkah '
            'yang sulit, bukan untuk pertanyaan sederhana.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'task': {'type': 'string'},
          },
          'required': ['task'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final task = '${args['task'] ?? ''}'.trim();
    if (task.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Parameter "task" wajib diisi.',
        isError: true,
      );
    }
    try {
      final result = await _engine.solve(task);
      return ToolResult(
        callId: '',
        content: const JsonEncoder.withIndent('  ').convert(result.toJson()),
      );
    } catch (e) {
      return ToolResult(callId: '', content: 'deep_solve gagal: $e', isError: true);
    }
  }
}
