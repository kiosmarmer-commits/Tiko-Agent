// Hermes parity: `agent/context_breakdown.py` — breakdown jendela konteks
// live untuk UI (`/context`): estimasi kategori system prompt, skema tool,
// dan percakapan. Occupancy keseluruhan mempertahankan provenance
// provider-usage (anchored, fase 9) atau estimasi; estimasi kategori BUKAN
// hitungan tokenizer eksak dan BUKAN otoritas gate.
//
// Aturan keanggotaan kategori (Hermes #87903): kategori dilaporkan bila nol
// adalah PENGUKURAN atas sesuatu yang dimiliki setiap sesi, bukan KETIDAK-
// ADAAN sesuatu yang opsional. `conversation` selalu dilaporkan (zero =
// "belum ada yang dibicarakan"); tool definitions/gambar hilang saat nol
// (baris 0-token permanen hanya noise).
library;

import 'context_builder.dart';
import 'usage_anchor.dart';

class ContextBreakdownResult {
  const ContextBreakdownResult({
    required this.systemPromptTokens,
    required this.toolDefinitionsTokens,
    required this.conversationTokens,
    required this.imageTokens,
    required this.totalTokens,
    required this.anchored,
  });

  /// Estimasi system prompt (chars/4).
  final int systemPromptTokens;

  /// Estimasi skema tool (name + description + inputSchema).
  final int toolDefinitionsTokens;

  /// Estimasi percakapan (isi pesan + tool calls; gambar dihitung terpisah).
  final int conversationTokens;

  /// Estimasi gambar pada harga per-gambar terikat turn (C7).
  final int imageTokens;

  /// Occupancy keseluruhan: angka ber-anchoring (usage nyata + delta) bila
  /// anchor fresh, selain itu penjumlahan estimasi kategori.
  final int totalTokens;

  /// True bila [totalTokens] ber-anchoring usage nyata provider.
  final bool anchored;

  Map<String, dynamic> toJson() => {
        'system_prompt_tokens': systemPromptTokens,
        if (toolDefinitionsTokens > 0)
          'tool_definitions_tokens': toolDefinitionsTokens,
        'conversation_tokens': conversationTokens,
        if (imageTokens > 0) 'image_tokens': imageTokens,
        'total_tokens': totalTokens,
        'anchored': anchored,
      };

  static ContextBreakdownResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int intOf(Object? v) => v is int && v >= 0 ? v : 0;
    return ContextBreakdownResult(
      systemPromptTokens: intOf(raw['system_prompt_tokens']),
      toolDefinitionsTokens: intOf(raw['tool_definitions_tokens']),
      conversationTokens: intOf(raw['conversation_tokens']),
      imageTokens: intOf(raw['image_tokens']),
      totalTokens: intOf(raw['total_tokens']),
      anchored: raw['anchored'] == true,
    );
  }
}

class ContextBreakdown {
  const ContextBreakdown._();

  /// Breakdown kategori atas [ctx]. Bila [anchor] masih cocok dengan
  /// transcript request, occupancy total memakai angka ber-anchoring.
  static ContextBreakdownResult compute(
    AgentContext ctx, {
    UsageAnchor? anchor,
    int imageCost = defaultImageTokenCost,
  }) {
    final systemPromptTokens = _textTokens(ctx.systemPrompt);
    var toolChars = 0;
    for (final t in ctx.tools) {
      toolChars += '${t.name}${t.description}'.length;
      toolChars += '${t.inputSchema}'.length;
    }
    final toolDefinitionsTokens = toolChars ~/ 4;
    var conversationChars = 0;
    var imageCount = 0;
    for (final m in ctx.messages) {
      conversationChars += m.content.length;
      if (m.toolCalls != null) {
        for (final c in m.toolCalls!) {
          conversationChars += c.name.length + c.id.length;
          c.args.forEach((k, v) => conversationChars += k.length + '$v'.length);
        }
      }
      imageCount += m.images?.length ?? 0;
    }
    final conversationTokens = conversationChars ~/ 4;
    final imageTokens = imageCount * imageCost;
    final estimateTotal =
        systemPromptTokens + toolDefinitionsTokens + conversationTokens + imageTokens;

    var totalTokens = estimateTotal;
    var anchored = false;
    if (anchor != null) {
      try {
        final anchoredTotal = anchor.anchoredContextTokens(
          ctx.toRequest().messages,
          imageCost: imageCost,
        );
        if (anchoredTotal != null) {
          totalTokens = anchoredTotal;
          anchored = true;
        }
      } catch (_) {} // best-effort
    }
    return ContextBreakdownResult(
      systemPromptTokens: systemPromptTokens,
      toolDefinitionsTokens: toolDefinitionsTokens,
      conversationTokens: conversationTokens,
      imageTokens: imageTokens,
      totalTokens: totalTokens,
      anchored: anchored,
    );
  }

  static int _textTokens(String text) => text.length ~/ 4;

  /// Render baris `/context` — kategori opsional nol-token dihilangkan,
  /// `conversation` selalu tampil (Hermes `_ALWAYS_REPORTED`).
  static List<String> formatLines(ContextBreakdownResult r) {
    final lines = <String>[
      'system prompt: ${r.systemPromptTokens} token',
    ];
    if (r.toolDefinitionsTokens > 0) {
      lines.add('skema tool: ${r.toolDefinitionsTokens} token');
    }
    lines.add('percakapan: ${r.conversationTokens} token');
    if (r.imageTokens > 0) {
      lines.add('gambar: ${r.imageTokens} token');
    }
    lines.add(
      'total: ${r.totalTokens} token '
      '(${r.anchored ? 'anchored usage provider' : 'estimasi kasar'})',
    );
    return lines;
  }
}
