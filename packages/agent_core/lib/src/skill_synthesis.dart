import 'dart:convert';

import 'interfaces.dart';
import 'models.dart';
import 'skills.dart';

/// FR-01 (Closed-Loop Self-Learning) — S_eval scoring + skill synthesis.
///
/// S_eval = w1·𝕀(success) + w2·toolTerm + w3·tokenTerm
///
/// - w1 (default 0.5): success indicator term
/// - w2 (default 0.3): tool-chain complexity term, saturating at
///   [maxToolCallsForScore] distinct tool calls
/// - w3 (default 0.2): efficiency term — fewer tokens than
///   [referenceTokens] scores higher
///
/// When S_eval ≥ [threshold] (default 0.85) the orchestrator compiles the
/// turn into a reusable SKILL.md draft.
class SkillEvalConfig {
  const SkillEvalConfig({
    this.w1 = 0.5,
    this.w2 = 0.3,
    this.w3 = 0.2,
    this.threshold = 0.85,
    this.maxToolCallsForScore = 10,
    this.referenceTokens = 20000,
  })  : assert(w1 + w2 + w3 > 0.99 && w1 + w2 + w3 < 1.01,
            'w1+w2+w3 must sum to 1.0'),
        assert(threshold >= 0 && threshold <= 1);

  final double w1;
  final double w2;
  final double w3;
  final double threshold;
  final int maxToolCallsForScore;
  final int referenceTokens;
}

/// Compiles successful multi-tool turns into reusable SKILL.md drafts.
class SkillSynthesis {
  /// Evaluates the S_eval score for a finished turn. Returns a value in
  /// [0, 1]; a failed turn always scores below the default threshold
  /// because its success term is 0.
  static double evalScore({
    required bool success,
    required int toolCalls,
    required int tokensUsed,
    SkillEvalConfig config = const SkillEvalConfig(),
  }) {
    final successTerm = success ? 1.0 : 0.0;

    final t = toolCalls < 0
        ? 0
        : (toolCalls > config.maxToolCallsForScore
            ? config.maxToolCallsForScore
            : toolCalls);
    final toolTerm = t / config.maxToolCallsForScore;

    final tk = tokensUsed < 0
        ? 0
        : (tokensUsed > config.referenceTokens
            ? config.referenceTokens
            : tokensUsed);
    final tokenTerm = 1.0 - tk / config.referenceTokens;

    final s = config.w1 * successTerm +
        config.w2 * toolTerm +
        config.w3 * tokenTerm;
    return s < 0 ? 0 : (s > 1 ? 1 : s);
  }

  /// Reflects on a successful turn via [llm] and persists a SKILL.md draft
  /// under [skillsDir]. Returns the saved skill, or null when the LLM
  /// output is unusable (the caller should then fall back to a naive
  /// draft).
  ///
  /// Never throws: synthesis is best-effort by design.
  static Future<Skill?> synthesizeDraft({
    required LlmProvider llm,
    required String goal,
    required String outcome,
    required List<String> tools,
    required String skillsDir,
    Set<String>? knownTools,
  }) async {
    try {
      final prompt = _reflectionPrompt(goal, outcome, tools);
      final req = ChatRequest(
        messages: [
          ChatMessage(role: 'system', content: _reflectionSystem),
          ChatMessage(role: 'user', content: prompt),
        ],
        stream: false,
        temperature: 0.2,
      );
      final buf = StringBuffer();
      await for (final ev in llm.chat(req)) {
        if (ev is LlmTextDelta) buf.write(ev.delta);
      }
      final raw = _extractJson(buf.toString());
      if (raw == null) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;

      final name = (map['name'] as String?)?.trim();
      final description = (map['description'] as String?)?.trim();
      if (name == null || name.isEmpty || description == null) return null;

      List<String> asStringList(dynamic v) => v is List
          ? v.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
          : const <String>[];

      final markdown = SkillDraftBuilder.build(
        name: name,
        description: description,
        triggers: asStringList(map['triggers']),
        tools: asStringList(map['tools']),
        steps: asStringList(map['steps']),
        failures: asStringList(map['failures']),
      );
      return await SkillDraftBuilder.saveDraft(
        markdown,
        skillsDir: skillsDir,
        knownTools: knownTools,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fallback draft compiled without an LLM (heuristics only), for
  /// runtimes without a spare provider.
  static Future<Skill?> naiveDraft({
    required String goal,
    required List<String> tools,
    required String skillsDir,
    Set<String>? knownTools,
  }) async {
    try {
      final words = goal
          .trim()
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.length > 2)
          .take(4)
          .toList();
      final name = words.isEmpty ? 'auto-skill' : words.join(' ');
      final markdown = SkillDraftBuilder.build(
        name: name,
        description: 'Draf otomatis dari eksekusi sukses: "$goal"',
        triggers: [goal.trim()],
        tools: tools,
        steps: [
          'Ulangi urutan tool: ${tools.join(' → ')}.',
          'Verifikasi hasil sebelum melaporkan ke pengguna.',
        ],
      );
      return await SkillDraftBuilder.saveDraft(
        markdown,
        skillsDir: skillsDir,
        knownTools: knownTools,
      );
    } catch (_) {
      return null;
    }
  }

  static String _reflectionPrompt(
    String goal,
    String outcome,
    List<String> tools,
  ) {
    final enc = JsonEncoder.withIndent('  ');
    return 'Tugas yang berhasil: ${enc.convert(goal)}\n'
        'Hasil akhir: ${enc.convert(outcome.isEmpty ? '(selesai)' : outcome)}\n'
        'Tool yang dipakai berurutan: ${enc.convert(tools)}\n\n'
        'Buat SATU objek JSON (tanpa teks lain) dengan bentuk:\n'
        '{"name": "nama_skill_pendek", '
        '"description": "deskripsi 1-2 kalimat kapan skill ini dipakai", '
        '"triggers": ["frasa pemicu"], '
        '"tools": ["tool_yang_dipakai"], '
        '"steps": ["langkah 1", "langkah 2"], '
        '"failures": ["kegagalan umum dan cara menghindarinya"]}';
  }

  static const _reflectionSystem =
      'Kamu adalah compiler skill untuk agent otonom. Kamu menerima '
      'transkrip tugas yang SUKSES dan merangkumnya menjadi skill yang bisa '
      'dipakai ulang. Balas HANYA dengan JSON valid.';

  /// Extracts the first balanced JSON object from [text], tolerating
  /// markdown fences around it.
  static String? _extractJson(String text) {
    var s = text.trim();
    if (s.startsWith('```')) {
      final firstNewline = s.indexOf('\n');
      if (firstNewline > 0) s = s.substring(firstNewline + 1);
      final fence = s.lastIndexOf('```');
      if (fence >= 0) s = s.substring(0, fence);
      s = s.trim();
    }
    final start = s.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (c == '\\' && i + 1 < s.length) {
          i++;
          continue;
        }
        if (c == '"') inString = false;
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return s.substring(start, i + 1);
      }
    }
    return null;
  }
}
