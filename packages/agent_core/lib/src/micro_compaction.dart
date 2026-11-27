/// Micro-compaction (Hermes `agent/micro_compaction.py`): kompresi bergulir
/// per-exchange yang melipat exchange lama (assistant + tool rows) menjadi
/// SATU marker ringkasan antar-turn. OFF by default — setiap pass menulis
/// ulang prefix prompt dan memutus provider prompt cache. Pesan user TIDAK
/// pernah diserap (alternasi role aman, teks user tetap verbatim).
library;

import 'compaction_events.dart';
import 'context_builder.dart';
import 'interfaces.dart';
import 'models.dart';

/// Prefix ringkasan — identik dengan [Compactor._summaryPrefix] agar marker
/// dikenali sebagai pesan ringkasan (bukan pesan aturan) di kompresi batch.
const microSummaryPrefix = 'Ringkasan percakapan sebelumnya:';

/// Tag yang membedakan marker micro (provably absorbed ke ringkasan bergulir)
/// dari marker batch — dipakai untuk rehydrate saat sesi dilanjutkan.
const microMarkerTag = '[micro]';

/// Statistik satu pass micro-compaction.
class MicroCompactionStats {
  const MicroCompactionStats({
    required this.absorbedExchanges,
    required this.messagesBefore,
    required this.messagesAfter,
    required this.absorbedChars,
    required this.summaryChars,
    required this.usedLlm,
    required this.defragged,
  });

  final int absorbedExchanges;
  final int messagesBefore;
  final int messagesAfter;
  final int absorbedChars;
  final int summaryChars;
  final bool usedLlm;
  final bool defragged;

  Map<String, dynamic> toJson() => {
        'absorbed_exchanges': absorbedExchanges,
        'messages_before': messagesBefore,
        'messages_after': messagesAfter,
        'absorbed_chars': absorbedChars,
        'summary_chars': summaryChars,
        'used_llm': usedLlm,
        'defragged': defragged,
      };
}

class MicroCompactor {
  MicroCompactor({
    this.enabled = false,
    this.keepLastExchanges = 2,
    this.maxSummaryTokens = 1500,
    this.defragThresholdTokens = 2000,
    this.clock,
    this.onCompactionEvent,
  });

  /// False menonaktifkan penuh (default Hermes) — ctx dilewati tanpa diubah.
  final bool enabled;

  /// Exchange terakhir yang selalu tetap panas (tidak pernah diserap).
  final int keepLastExchanges;

  final int maxSummaryTokens;

  /// Ringkasan bergulir ≥ token ini → di-defrag (di-ringkas ulang) pass ini.
  final int defragThresholdTokens;

  final double Function()? clock;

  /// Hermes compaction events: record `micro_summarize` per pass yang
  /// benar-benar menyerap exchange (committed). Never-raises.
  final CompactionEventCallback? onCompactionEvent;

  String _rollingSummary = '';
  int _cursor = 0;

  /// Ringkasan bergulir saat ini (untuk observability host).
  String get rollingSummary => _rollingSummary;

  MicroCompactionStats? last;

  ChatMessage _marker() => ChatMessage(
        role: 'system',
        content: '$microSummaryPrefix\n$microMarkerTag\n$_rollingSummary',
      );

  static bool _isMarker(ChatMessage m) =>
      m.content.startsWith(microSummaryPrefix) &&
      m.content.contains(microMarkerTag);

  /// Pemulihan sesi lanjutan: ringkasan bergulir di-rehydrate dari marker
  /// yang selamat di transcript sehingga pass berikutnya MERGE, bukan replace.
  static String summaryFromMarker(ChatMessage m) {
    if (!m.content.startsWith(microSummaryPrefix)) return '';
    final body = m.content.substring(microSummaryPrefix.length).trim();
    if (body.startsWith(microMarkerTag)) {
      return body.substring(microMarkerTag.length).trim();
    }
    return body;
  }

  int _estTokens(String s) => s.length ~/ 4;

  /// Satu pass micro-compaction atas [ctx]. Return ctx baru bila ada exchange
  /// yang diserap; ctx asli bila tidak ada perubahan (fail-open).
  Future<AgentContext> maybeMicroCompact(
    AgentContext ctx, {
    LlmProvider? summarizer,
  }) async {
    if (!enabled) return ctx;
    final messages = ctx.messages;
    if (messages.length <= keepLastExchanges * 2 + 1) return ctx;

    final defragged = await _maybeDefrag(summarizer);

    // tailStart = user message pembuka dari keepLastExchanges user turn
    // terakhir; region [0, tailStart) adalah wilayah yang boleh diserap.
    final userIdx = <int>[
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == 'user') i,
    ];
    if (userIdx.length <= keepLastExchanges) return ctx;
    final tailStart = userIdx[userIdx.length - keepLastExchanges];

    // Cursor: valid bila masih di dalam wilayah; else pulihkan dari marker
    // micro terakhir (sesi lanjutan), else mulai dari 0.
    if (_cursor < 0 || _cursor > tailStart) _cursor = 0;
    if (_cursor == 0) {
      for (var i = 0; i < tailStart; i++) {
        if (_isMarker(messages[i])) {
          _cursor = i + 1;
          if (_rollingSummary.isEmpty) {
            _rollingSummary = summaryFromMarker(messages[i]);
          }
        }
      }
    }

    final absorbed = <int>{};
    var exchangeCount = 0;
    var absorbedChars = 0;
    var usedLlm = false;
    var cursor = _cursor;
    while (cursor < tailStart) {
      final span = _findOneExchange(messages, cursor, tailStart);
      if (span == null) break;
      final (start, end) = span;
      final exchangeText = _exchangeText(messages, start, end);
      if (exchangeText.isEmpty) {
        cursor = end;
        continue;
      }
      final merged = await _merge(exchangeText, summarizer);
      if (merged == null) break;
      _rollingSummary = merged;
      for (var i = start; i < end; i++) {
        absorbed.add(i);
        absorbedChars += messages[i].content.length;
      }
      exchangeCount++;
      usedLlm = usedLlm || summarizer != null;
      cursor = end;
    }
    _cursor = cursor;
    if (absorbed.isEmpty) {
      return ctx;
    }

    final tokensBefore = messages.fold<int>(0, (s, m) => s + m.content.length) ~/ 4;
    final outLen = messages.length - absorbed.length + 1;
    try {
      onCompactionEvent?.call(CompactionEvent(
        kind: 'micro_summarize',
        trigger: 'turn_start_threshold',
        method: usedLlm ? 'llm_summary' : 'deterministic_fallback',
        outcome: 'committed',
        tokensBefore: tokensBefore,
        tokensAfter: (tokensBefore - absorbedChars ~/ 4) + _rollingSummary.length ~/ 4,
        messagesBefore: messages.length,
        messagesAfter: outLen,
        durationMs: 0,
        ts: DateTime.now().toUtc(),
      ));
    } catch (_) {}

    final out = <ChatMessage>[];
    var markerWritten = false;
    for (var i = 0; i < messages.length; i++) {
      if (absorbed.contains(i)) {
        if (!markerWritten) {
          out.add(_marker());
          markerWritten = true;
        }
        continue;
      }
      if (!markerWritten && i == tailStart && _rollingSummary.isNotEmpty) {
        out.add(_marker());
        markerWritten = true;
      }
      out.add(messages[i]);
    }

    last = MicroCompactionStats(
      absorbedExchanges: exchangeCount,
      messagesBefore: messages.length,
      messagesAfter: out.length,
      absorbedChars: absorbedChars,
      summaryChars: _rollingSummary.length,
      usedLlm: usedLlm,
      defragged: defragged,
    );

    return AgentContext(
      messages: out,
      tools: ctx.tools,
      session: ctx.session..summary = _rollingSummary,
      systemPrompt: ctx.systemPrompt,
    )..recentToolCalls.addAll(ctx.recentToolCalls);
  }

  /// Exchange lengkap berikutnya mulai [start]: assistant + tool rows sampai
  /// batas non-(assistant|tool). Return (start, end) atau null.
  (int, int)? _findOneExchange(
    List<ChatMessage> messages,
    int start,
    int tailStart,
  ) {
    final limit = tailStart < messages.length ? tailStart : messages.length;
    var idx = start;
    while (idx < limit && messages[idx].role != 'assistant') {
      idx++;
    }
    if (idx >= limit) return null;
    final exchangeStart = idx;
    idx++;
    while (idx < limit &&
        (messages[idx].role == 'assistant' || messages[idx].role == 'tool')) {
      idx++;
    }
    if (idx < messages.length &&
        (messages[idx].role == 'assistant' || messages[idx].role == 'tool')) {
      return null;
    }
    return (exchangeStart, idx);
  }

  String _exchangeText(List<ChatMessage> messages, int start, int end) {
    final parts = <String>[];
    for (var i = start; i < end; i++) {
      final m = messages[i];
      final text = m.content.trim();
      if (text.isEmpty) continue;
      if (m.role == 'assistant') {
        parts.add(
          text.length > 400 ? '${text.substring(0, 400)}…' : text,
        );
      } else if (m.role == 'tool') {
        parts.add(
          'Tool(${m.name ?? 'tool'}): '
          '${text.length > 160 ? '${text.substring(0, 160)}…' : text}',
        );
      }
    }
    return parts.join('\n');
  }

  /// Gabungkan teks exchange ke ringkasan bergulir. Null bila merge gagal —
  /// exchange dibiarkan tidak diserap agar pass berikutnya mencoba lagi.
  Future<String?> _merge(String exchangeText, LlmProvider? summarizer) async {
    if (summarizer == null) return _naiveMerge(exchangeText);
    try {
      final summaryBlock = _rollingSummary.trim().isEmpty
          ? '(No previous summary yet.)'
          : _rollingSummary;
      final prompt =
          'You are a summarization agent creating a compact record of an '
          'ongoing conversation. You are given a running summary and the '
          "next exchange from the conversation. Merge the exchange's key "
          'decisions, requirements, file paths, and open questions into the '
          "summary. Preserve the summary's structure. Drop resolved details "
          'that are no longer relevant. Add new decisions, file paths, and '
          'open questions.\n\n'
          'NEVER include API keys, tokens, passwords, secrets, credentials, '
          'or connection strings in the summary — replace any that appear '
          'with [REDACTED].\n\n'
          '## Current Running Summary\n$summaryBlock\n\n'
          '## Next Exchange to Merge\n$exchangeText\n\n'
          'Return ONLY the updated summary text, no preamble or explanation. '
          'Do not include this instruction block in your output.';
      final buf = StringBuffer();
      String? finish;
      await for (final e in summarizer.chat(ChatRequest(
        messages: [
          const ChatMessage(
            role: 'system',
            content: 'You are a conversation summarization assistant.',
          ),
          ChatMessage(role: 'user', content: prompt),
        ],
        stream: false,
        temperature: 0.1,
        maxTokens: maxSummaryTokens < 1500 ? maxSummaryTokens : 1500,
      ))) {
        switch (e) {
          case LlmTextDelta(:final delta):
            buf.write(delta);
          case LlmDone(:final finishReason):
            finish = finishReason;
          default:
            break;
        }
      }
      // Length stop berarti merge parsial — exchange dibiarkan tidak diserap
      // agar pass berikutnya mencoba lagi (kontrak Hermes).
      if (finish == 'length') return null;
      final out = _stripThink(buf.toString()).trim();
      if (out.isEmpty) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _maybeDefrag(LlmProvider? summarizer) async {
    if (_estTokens(_rollingSummary) < defragThresholdTokens) return false;
    final old = _rollingSummary;
    _rollingSummary = '';
    final fresh = summarizer == null ? null : await _merge(old, summarizer);
    _rollingSummary = fresh ?? old;
    return fresh != null;
  }

  String _naiveMerge(String exchangeText) {
    final lines = exchangeText
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim().length > 160 ? '${l.substring(0, 160)}…' : l)
        .take(12)
        .toList();
    final addition = lines.join('\n');
    if (_rollingSummary.trim().isEmpty) return addition;
    return '$_rollingSummary\n$addition';
  }

  String _stripThink(String text) {
    final re = RegExp(r'<think>.*?</think>', dotAll: true);
    return text.replaceAll(re, '');
  }
}
