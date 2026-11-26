/// Side question `/btw` (Hermes `agent/side_question.py`): jawab pertanyaan
/// TENTANG percakapan tanpa menyentuhnya — tanpa synthetic turn, tanpa
/// risiko role-alternation, tanpa meng-invalidate prompt cache.
///
/// Path fallback (tanpa live parent): transcript dirender plain-text,
/// bias-terbaru, dipadatkan ke budget karakter, lalu dijawab one-shot oleh
/// provider auxiliary. Tool DILARANG untuk side question.
library;

const sideQuestionPerMessageCharCap = 2000;
const sideQuestionTranscriptCharBudget = 24000;

const sideQuestionInstructions =
    'You are the same AI assistant that is currently working inside the '
    'conversation transcribed below. The user has asked a quick SIDE question '
    'with /btw while the main work continues.\n'
    'Rules:\n'
    '- Answer ONLY the side question. Do not continue, redo, or critique the '
    'main task.\n'
    '- Use the transcript as your primary context; it is a snapshot and may '
    'not include the very latest activity.\n'
    '- Do NOT call any tools — they are disabled for this side question. '
    'Answer directly in text.\n'
    '- If the transcript does not contain enough information to answer, say '
    'so plainly instead of guessing.\n'
    '- Be concise and direct.';

const sideQuestionDeniedToolMessage =
    'Side question (/btw) menolak tool call: {tool_name}. Jawab langsung '
    'dalam teks.';

const _roleLabels = {
  'user': 'USER',
  'assistant': 'ASSISTANT',
  'tool': 'TOOL RESULT',
};

/// Buang pesan ekor snapshot sampai berakhir dengan assistant text yang
/// selesai (tanpa tool_calls). Ekor mid-turn (tool result, tool_calls
/// menggantung, user in-flight) merusak role alternation di provider
/// ketat; memotong EKOR saja menjaga prefix cache tetap hangat.
List<Map<String, dynamic>> trimSnapshotForFork(
  List<Map<String, dynamic>> history,
) {
  final msgs = List<Map<String, dynamic>>.of(history);
  while (msgs.isNotEmpty) {
    final last = msgs.last;
    final isAssistantText = last['role'] == 'assistant' &&
        (last['tool_calls'] == null || (last['tool_calls'] as List?)!.isEmpty);
    if (isAssistantText) break;
    msgs.removeLast();
  }
  return msgs;
}

String _msgText(Map<String, dynamic> msg) {
  final content = msg['content'];
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .map((p) => p['text']?.toString() ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n');
  }
  return '';
}

/// Transcript plain-text untuk path fallback: bias-terbaru, dipadatkan ke
/// [charBudget], tool call diringkas nama, tool result dipangkas, system
/// prompt dilewati.
String renderHistoryForSideQuestion(
  List<Map<String, dynamic>>? history, {
  int charBudget = sideQuestionTranscriptCharBudget,
}) {
  final lines = <String>[];
  for (final msg in history ?? const <Map<String, dynamic>>[]) {
    final role = msg['role']?.toString();
    if (role == 'system') continue;
    final text = _msgText(msg);
    if (role == 'assistant' && msg['tool_calls'] is List) {
      final names = (msg['tool_calls'] as List)
          .whereType<Map>()
          .map((tc) =>
              ((tc['function'] as Map?)?['name'] ?? tc['name'] ?? '?')
                  .toString())
          .join(', ');
      lines.add('ASSISTANT [called tools: $names]');
    }
    final label = _roleLabels[role];
    if (label != null && text.isNotEmpty) {
      final capped = text.length > sideQuestionPerMessageCharCap
          ? '${text.substring(0, sideQuestionPerMessageCharCap)}…'
          : text;
      lines.add('$label: $capped');
    }
  }

  final kept = <String>[];
  var used = 0;
  for (final line in lines.reversed) {
    if (used + line.length + 1 > charBudget && kept.isNotEmpty) break;
    kept.add(line);
    used += line.length + 1;
  }
  if (kept.isEmpty) return '(no prior conversation)';
  final prefix =
      kept.length < lines.length ? '[...older conversation omitted...]\n' : '';
  return prefix + kept.reversed.join('\n');
}

/// Prompt user final untuk one-shot side question.
String buildSideQuestionPrompt({
  required String transcript,
  required String question,
}) {
  return '$sideQuestionInstructions\n\n'
      'Conversation transcript:\n\n$transcript\n\n'
      'SIDE QUESTION: $question\n\n'
      'Answer the side question directly in text.';
}
