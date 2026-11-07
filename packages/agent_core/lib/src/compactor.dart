import 'interfaces.dart';
import 'context_builder.dart';
import 'models.dart';

/// Compacts conversation history when approaching context limit (ALG-05).
class Compactor {
  Compactor({
    this.thresholdRatio = 0.7,
    this.keepLastN = 6,
    this.maxSoftTokens = 6000,
    this.llm,
  });

  final double thresholdRatio;
  final int keepLastN;
  final int maxSoftTokens;

  /// Optional small model for better summaries.
  final LlmProvider? llm;

  Future<AgentContext> maybeCompact(AgentContext ctx) async {
    final chars = ctx.messages.fold<int>(0, (s, m) => s + m.content.length);
    final estTokens = chars ~/ 4;
    final limit = (ctx.session.summary != null ? maxSoftTokens : maxSoftTokens);
    if (estTokens < limit * thresholdRatio) return ctx;

    final keep = ctx.messages.length <= keepLastN
        ? ctx.messages
        : ctx.messages.sublist(ctx.messages.length - keepLastN);

    final summary = llm != null
        ? await _llmSummary(ctx.messages)
        : _naiveSummary(ctx.messages);

    final compacted = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content: 'Ringkasan percakapan sebelumnya:\n$summary',
      ),
      ...keep,
    ];

    return AgentContext(
      messages: compacted,
      tools: ctx.tools,
      session: ctx.session..summary = summary,
      systemPrompt: ctx.systemPrompt,
    )..recentToolCalls.addAll(ctx.recentToolCalls);
  }

  Future<String> _llmSummary(List<ChatMessage> messages) async {
    final transcript = _naiveSummary(messages);
    try {
      final req = ChatRequest(
        messages: [
          const ChatMessage(
            role: 'system',
            content:
                'Ringkas percakapan agent dalam bahasa Indonesia, maks 12 kalimat. '
                'Pertahankan fakta, keputusan, path file, dan hasil tool penting.',
          ),
          ChatMessage(role: 'user', content: transcript),
        ],
        stream: false,
        temperature: 0.2,
        maxTokens: 400,
      );
      final buf = StringBuffer();
      await for (final e in llm!.chat(req)) {
        if (e is LlmTextDelta) buf.write(e.delta);
      }
      final out = buf.toString().trim();
      return out.isEmpty ? transcript : out;
    } catch (_) {
      return _naiveSummary(messages);
    }
  }

  String _naiveSummary(List<ChatMessage> messages) {
    final parts = <String>[];
    for (final m in messages) {
      if (m.role == 'user') {
        parts.add(
          'User: ${m.content.length > 120 ? '${m.content.substring(0, 120)}…' : m.content}',
        );
      } else if (m.role == 'assistant' && m.content.isNotEmpty) {
        parts.add(
          'Assistant: ${m.content.length > 120 ? '${m.content.substring(0, 120)}…' : m.content}',
        );
      } else if (m.role == 'tool') {
        final name = m.name ?? 'tool';
        parts.add(
          'Tool($name): ${m.content.length > 80 ? '${m.content.substring(0, 80)}…' : m.content}',
        );
      }
    }
    return parts.take(12).join('\n');
  }
}
