import 'dart:convert';

import 'package:agent_core/agent_core.dart';

/// Fallback DecisionProvider: ask an LlmProvider to answer typed questions as JSON.
class LlmJsonDecisionProvider implements DecisionProvider {
  LlmJsonDecisionProvider(this.llm, {this.model});

  final LlmProvider llm;
  final String? model;

  @override
  Future<DecisionResult> decide(
    String state,
    Map<String, Question> questions,
  ) async {
    final schemaHint = questions.entries
        .map((e) {
          final q = e.value;
          if (q is ChoiceQuestion) {
            return '"${e.key}": {"type":"choice","choice":"<one of ${q.options}>","confidence":0-1}';
          }
          if (q is ScoreQuestion) {
            return '"${e.key}": {"type":"score","score":${q.min}-${q.max},"confidence":0-1}';
          }
          if (q is NoulQuestion) {
            return '"${e.key}": {"type":"noul","noul":0-1,"confidence":0-1}';
          }
          return '"${e.key}": {}';
        })
        .join(',\n');

    final prompt =
        '''
Anda adalah model keputusan. Jawab HANYA JSON valid tanpa markdown.
State:
$state

Questions — isi objek answers dengan:
{
  "answers": {
$schemaHint
  }
}
''';

    final req = ChatRequest(
      messages: [
        const ChatMessage(role: 'system', content: 'Output JSON only.'),
        ChatMessage(role: 'user', content: prompt),
      ],
      stream: false,
      model: model,
      temperature: 0,
    );

    final buf = StringBuffer();
    await for (final e in llm.chat(req)) {
      if (e is LlmTextDelta) buf.write(e.delta);
      if (e is LlmError) throw StateError(e.message);
    }

    var text = buf.toString().trim();
    // strip optional fences
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      text = text.replaceFirst(RegExp(r'\s*```$'), '');
    }

    final json = jsonDecode(text) as Map<String, dynamic>;
    return DecisionResult.fromJson(json);
  }
}

/// Deterministic heuristic decision provider for offline tests / no model.
class HeuristicDecisionProvider implements DecisionProvider {
  @override
  Future<DecisionResult> decide(
    String state,
    Map<String, Question> questions,
  ) async {
    final lower = state.toLowerCase();
    final answers = <String, Answer>{};

    for (final e in questions.entries) {
      final name = e.key;
      final q = e.value;
      if (q is NoulQuestion) {
        double p = 0.1;
        if (name.contains('tool') || name == 'butuh_tool') {
          p = _needTool(lower) ? 0.85 : 0.15;
        } else if (name.contains('bahaya') || name == 'berbahaya') {
          p = _dangerous(lower) ? 0.9 : 0.05;
        } else {
          p = 0.3;
        }
        answers[name] = Answer(
          type: 'noul',
          noul: p,
          confidence: 0.7,
          probabilities: {'yes': p, 'no': 1 - p},
        );
      } else if (q is ChoiceQuestion) {
        String choice = q.options.isNotEmpty ? q.options.first : 'unknown';
        if (name == 'kompleksitas' || name.contains('kompleks')) {
          if (lower.length > 200 ||
              lower.contains('rencana') ||
              lower.contains('analisis')) {
            choice = q.options.contains('berat') ? 'berat' : q.options.last;
          } else if (_needTool(lower)) {
            choice = q.options.contains('sedang') ? 'sedang' : choice;
          } else {
            choice = q.options.contains('ringan') ? 'ringan' : choice;
          }
        }
        answers[name] = Answer(type: 'choice', choice: choice, confidence: 0.6);
      } else if (q is ScoreQuestion) {
        answers[name] = Answer(
          type: 'score',
          score: (q.min + q.max) / 2,
          confidence: 0.5,
        );
      }
    }
    return DecisionResult(answers);
  }

  bool _needTool(String s) {
    const keys = [
      'hitung',
      'cari',
      'baca',
      'tulis',
      'jalankan',
      'waktu',
      'tanggal',
      'file',
      'folder',
      'web',
      'shell',
      'jadwal',
      'schedule',
      'unduh',
    ];
    return keys.any(s.contains);
  }

  bool _dangerous(String s) {
    const keys = [
      'rm -rf',
      'hapus semua',
      'format disk',
      'kirim .env',
      'api key',
      'password',
      'sudo',
      'curl | sh',
      'wget | sh',
      'drop table',
    ];
    return keys.any(s.contains);
  }
}
