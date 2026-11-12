import 'interfaces.dart';
import 'models.dart';

/// Simple plan-and-execute helper (ALG-02).
///
/// Asks the LLM for a numbered plan, then returns steps as strings.
/// The host AgentLoop can execute steps as successive user turns or tool goals.
class PlanExecute {
  PlanExecute(this.llm);

  final LlmProvider llm;

  Future<List<String>> plan(String goal, {int maxSteps = 6}) async {
    final req = ChatRequest(
      messages: [
        ChatMessage(
          role: 'system',
          content:
              'Buat rencana langkah untuk mencapai tujuan. '
              'Output HANYA daftar bernomor 1..N (maks $maxSteps), satu langkah per baris, tanpa pengantar.',
        ),
        ChatMessage(role: 'user', content: goal),
      ],
      stream: false,
      temperature: 0.2,
      maxTokens: 400,
    );
    final buf = StringBuffer();
    await for (final e in llm.chat(req)) {
      if (e is LlmTextDelta) buf.write(e.delta);
    }
    return _parseSteps(buf.toString(), maxSteps);
  }

  static List<String> parseStepsForTest(String text, int maxSteps) =>
      _parseSteps(text, maxSteps);

  static List<String> _parseSteps(String text, int maxSteps) {
    final steps = <String>[];
    for (final line in text.split('\n')) {
      final t = line.trim();
      final m = RegExp(r'^\d+[.)]\s*(.+)$').firstMatch(t);
      if (m != null) {
        steps.add(m.group(1)!.trim());
      } else if (t.startsWith('- ')) {
        steps.add(t.substring(2).trim());
      }
      if (steps.length >= maxSteps) break;
    }
    if (steps.isEmpty && text.trim().isNotEmpty) {
      steps.add(text.trim());
    }
    return steps;
  }
}

/// Reflection / critic pass (ALG-03).
class Reflector {
  Reflector(this.llm);

  final LlmProvider llm;

  /// Returns critique + optional revised answer.
  Future<({String critique, String? revision})> reflect({
    required String goal,
    required String answer,
    required List<String> toolTrace,
  }) async {
    final req = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content:
              'Anda kritikus singkat. Evaluasi apakah jawaban memenuhi tujuan. '
              'Format:\nCRITIQUE: ...\nREVISE: (opsional jawaban perbaikan, atau NONE)',
        ),
        ChatMessage(
          role: 'user',
          content:
              'Tujuan: $goal\n\nJejak tool:\n${toolTrace.join('\n')}\n\nJawaban:\n$answer',
        ),
      ],
      stream: false,
      temperature: 0.2,
      maxTokens: 500,
    );
    final buf = StringBuffer();
    await for (final e in llm.chat(req)) {
      if (e is LlmTextDelta) buf.write(e.delta);
    }
    final text = buf.toString();
    String critique = text.trim();
    String? revision;
    final critMatch = RegExp(
      r'CRITIQUE:\s*(.+?)(?=REVISE:|$)',
      dotAll: true,
    ).firstMatch(text);
    if (critMatch != null) critique = critMatch.group(1)!.trim();
    final revMatch = RegExp(r'REVISE:\s*(.+)$', dotAll: true).firstMatch(text);
    if (revMatch != null) {
      final r = revMatch.group(1)!.trim();
      if (r.isNotEmpty && r.toUpperCase() != 'NONE') revision = r;
    }
    return (critique: critique, revision: revision);
  }
}
