import 'interfaces.dart';
import 'models.dart';

/// Self-consistency: sample N answers, pick majority / best (ALG optional).
class SelfConsistency {
  SelfConsistency(this.llm, {this.samples = 3});

  final LlmProvider llm;
  final int samples;

  Future<String> answer({
    required List<ChatMessage> messages,
    double temperature = 0.7,
  }) async {
    if (samples <= 1) {
      return _one(messages, temperature);
    }
    final futures = List.generate(samples, (_) => _one(messages, temperature));
    final answers = await Future.wait(futures);
    final cleaned = answers
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) return '';
    // majority by normalized text
    final counts = <String, int>{};
    for (final a in cleaned) {
      final key = a.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final bestKey = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    return cleaned.firstWhere(
      (a) => a.toLowerCase().replaceAll(RegExp(r'\s+'), ' ') == bestKey,
      orElse: () => cleaned.first,
    );
  }

  Future<String> _one(List<ChatMessage> messages, double temperature) async {
    final buf = StringBuffer();
    await for (final e in llm.chat(
      ChatRequest(messages: messages, stream: false, temperature: temperature),
    )) {
      if (e is LlmTextDelta) buf.write(e.delta);
    }
    return buf.toString();
  }
}
