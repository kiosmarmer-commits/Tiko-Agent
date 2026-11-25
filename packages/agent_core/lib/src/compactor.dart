import 'interfaces.dart';
import 'context_builder.dart';
import 'models.dart';

/// Statistik satu kali kandidat kompresi konteks diperiksa. [compacted] true
/// berarti riwayat benar-benar dipangkas; false berarti ctx dilewati apa
/// adanya (di bawah ambang, atau compactor dimatikan).
class CompactionStats {
  const CompactionStats({
    required this.compacted,
    required this.messagesBefore,
    required this.messagesAfter,
    required this.estTokensBefore,
    required this.estTokensAfter,
    required this.usedLlm,
    this.summary,
  });

  final bool compacted;
  final int messagesBefore;
  final int messagesAfter;
  final int estTokensBefore;
  final int estTokensAfter;

  /// True bila ringkasan dicoba dengan LLM (ctor [Compactor.llm] atau
  /// [Compactor.maybeCompact.llmOverride]); false berarti heuristic naive.
  final bool usedLlm;
  final String? summary;

  Map<String, dynamic> toJson() => {
    'compacted': compacted,
    'messages_before': messagesBefore,
    'messages_after': messagesAfter,
    'est_tokens_before': estTokensBefore,
    'est_tokens_after': estTokensAfter,
    'used_llm': usedLlm,
  };
}

/// Compacts conversation history when approaching context limit (ALG-05).
class Compactor {
  Compactor({
    this.enabled = true,
    this.thresholdRatio = 0.7,
    this.keepLastN = 6,
    this.maxSoftTokens = 6000,
    this.llm,
    this.onCompaction,
  });

  /// False menonaktifkan kompresi penuh: ctx selalu dilewati tanpa diubah.
  final bool enabled;
  final double thresholdRatio;
  final int keepLastN;
  final int maxSoftTokens;

  /// Optional small model for better summaries. Di dalam AgentLoop, pemanggil
  /// biasanya meneruskan LLM aktif turn lewat [Compactor.maybeCompact].
  final LlmProvider? llm;

  /// Callback observability: dipanggil pada setiap kandidat kompresi yang
  /// benar-benar dipangkas. Kegagalan callback tidak dipropagasi.
  final void Function(CompactionStats stats)? onCompaction;

  /// Statistik kompresi terakhir (null bila belum ada yang dipangkas).
  CompactionStats? lastCompaction;

  Future<AgentContext> maybeCompact(
    AgentContext ctx, {
    LlmProvider? llmOverride,
  }) async {
    if (!enabled) return ctx;
    final chars = ctx.messages.fold<int>(0, (s, m) => s + m.content.length);
    final estTokensBefore = chars ~/ 4;
    if (estTokensBefore < maxSoftTokens * thresholdRatio) return ctx;

    final messagesBefore = ctx.messages.length;
    final keep = messagesBefore <= keepLastN
        ? ctx.messages
        : ctx.messages.sublist(messagesBefore - keepLastN);

    final summarizer = llmOverride ?? llm;
    final summary = summarizer != null
        ? await _llmSummary(summarizer, ctx.messages)
        : _naiveSummary(ctx.messages);
    final estTokensAfter = summary.length ~/ 4 + _estTokens(keep);

    final compacted = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content: 'Ringkasan percakapan sebelumnya:\n$summary',
      ),
      ...keep,
    ];

    final stats = CompactionStats(
      compacted: true,
      messagesBefore: messagesBefore,
      messagesAfter: compacted.length,
      estTokensBefore: estTokensBefore,
      estTokensAfter: estTokensAfter,
      usedLlm: summarizer != null,
      summary: summary,
    );
    lastCompaction = stats;
    try {
      onCompaction?.call(stats);
    } catch (_) {}

    return AgentContext(
      messages: compacted,
      tools: ctx.tools,
      session: ctx.session..summary = summary,
      systemPrompt: ctx.systemPrompt,
    )..recentToolCalls.addAll(ctx.recentToolCalls);
  }

  Future<String> _llmSummary(
    LlmProvider summarizer,
    List<ChatMessage> messages,
  ) async {
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
      await for (final e in summarizer.chat(req)) {
        if (e is LlmTextDelta) buf.write(e.delta);
      }
      final out = buf.toString().trim();
      return out.isEmpty ? transcript : out;
    } catch (_) {
      return _naiveSummary(messages);
    }
  }

  int _estTokens(List<ChatMessage> messages) =>
      messages.fold<int>(0, (s, m) => s + m.content.length ~/ 4);

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
