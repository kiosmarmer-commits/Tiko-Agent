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
    this.rulesRetained = 0,
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

  /// Type-aware (R2): jumlah pesan aturan/keamanan yang dipertahankan
  /// verbatim dan tidak pernah masuk ringkasan yang dipangkas.
  final int rulesRetained;

  Map<String, dynamic> toJson() => {
    'compacted': compacted,
    'messages_before': messagesBefore,
    'messages_after': messagesAfter,
    'est_tokens_before': estTokensBefore,
    'est_tokens_after': estTokensAfter,
    'used_llm': usedLlm,
    'rules_retained': rulesRetained,
  };
}

/// Statistik satu kali proactive tool-result prune (Hermes-style,
/// `turn_proactive_prune.py`). [pruned] true berarti minimal satu hasil
/// tool besar diganti stub; konten aslinya diarsipkan agar bisa di-recall.
class ToolResultPruneStats {
  const ToolResultPruneStats({
    required this.pruned,
    required this.pruneCount,
    required this.charsBefore,
    required this.charsAfter,
  });

  final bool pruned;
  final int pruneCount;
  final int charsBefore;
  final int charsAfter;

  Map<String, dynamic> toJson() => {
        'pruned': pruned,
        'prune_count': pruneCount,
        'chars_before': charsBefore,
        'chars_after': charsAfter,
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
    this.preserve,
    this.pruneToolResultsEnabled = true,
    this.maxToolResultChars = 8000,
    this.keepLastToolResults = 2,
    this.maxArchivedToolResults = 32,
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

  /// Type-aware retention (R2): predicate tambahan untuk menandai pesan yang
  /// harus dipertahankan verbatim (mis. aturan keamanan kustom dari caller).
  /// Pesan aturan bawaan (role system non-ringkasan, atau teks dengan penanda
  /// aturan) sudah dilindungi otomatis oleh [isRuleMessage].
  final bool Function(ChatMessage message)? preserve;

  /// Proactive tool-result prune (Hermes `turn_proactive_prune`): hasil tool
  /// yang besar diganti stub tanpa LLM, jauh lebih murah daripada kompresi
  /// penuh. False untuk menonaktifkan.
  final bool pruneToolResultsEnabled;

  /// Hasil tool dengan konten lebih panjang dari ini menjadi kandidat prune.
  final int maxToolResultChars;

  /// N hasil tool terakhir selalu tetap panas (belum di-prune) karena model
  /// paling mungkin masih membutuhkannya di iterasi berikutnya.
  final int keepLastToolResults;

  /// Batas arsip in-memory hasil tool yang di-prune (LRU) agar memori
  /// tidak tumbuh tanpa batas sepanjang sesi.
  final int maxArchivedToolResults;

  /// Arsip in-memory konten asli hasil tool yang di-prune, dikunci dengan
  /// key stub. Baca lewat [recallToolResult]. LRU: entri terlama dibuang.
  final Map<String, String> _pruneArchive = {};
  int _pruneSeq = 0;

  /// Statistik prune terakhir (null bila belum ada yang dipangkas).
  ToolResultPruneStats? lastPrune;

  /// Konten asli hasil tool yang sudah di-prune, bila key masih berada di
  /// dalam arsip LRU. Null bila key tidak dikenal.
  String? recallToolResult(String key) => _pruneArchive[key];

  /// Key-key konten hasil tool yang masih berada di dalam arsip LRU.
  List<String> get archivedToolResultKeys =>
      List.unmodifiable(_pruneArchive.keys);

  /// Proactive tool-result prune (Hermes `turn_proactive_prune.py`, versi
  /// tanpa I/O): hasil tool berukuran besar — kecuali [keepLastToolResults]
  /// hasil terakhir yang masih panas — diganti stub pendek dan konten
  /// aslinya diarsipkan in-memory untuk recall. Deterministik, sinkron,
  /// dan tanpa jaringan; kontrak commit Hermes (hitung perubahan, jangan
  /// pernah membuang iterasi terakhir) dijaga lewat keep-last.
  AgentContext pruneToolResults(AgentContext ctx) {
    if (!enabled || !pruneToolResultsEnabled) return ctx;
    final messages = ctx.messages;
    final toolIndexes = <int>[
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == 'tool') i,
    ];
    // Hasil tool paling akhir tetap panas.
    final cold = toolIndexes.length <= keepLastToolResults
        ? const <int>[]
        : toolIndexes.sublist(0, toolIndexes.length - keepLastToolResults);
    if (cold.isEmpty) return ctx;

    var prunedCount = 0;
    final charsBefore = messages.fold<int>(0, (s, m) => s + m.content.length);
    final next = List<ChatMessage>.from(messages);
    for (final i in cold) {
      final m = next[i];
      if (m.content.length <= maxToolResultChars) continue;
      if (m.content.startsWith(_pruneStubPrefix)) continue;
      final key = 'prune-${_pruneSeq++}';
      _archivePruned(key, m.content);
      prunedCount++;
      next[i] = ChatMessage(
        role: 'tool',
        content:
            '$_pruneStubPrefix${m.name ?? 'tool'} ($key, '
            '${m.content.length} chars). Konten asli diarsipkan; '
            'minta recall bila diperlukan.',
        toolCallId: m.toolCallId,
        name: m.name,
      );
    }
    if (prunedCount == 0) return ctx;
    final charsAfter = next.fold<int>(0, (s, m) => s + m.content.length);
    final stats = ToolResultPruneStats(
      pruned: true,
      pruneCount: prunedCount,
      charsBefore: charsBefore,
      charsAfter: charsAfter,
    );
    lastPrune = stats;
    return AgentContext(
      messages: next,
      tools: ctx.tools,
      session: ctx.session,
      systemPrompt: ctx.systemPrompt,
    )..recentToolCalls.addAll(ctx.recentToolCalls);
  }

  static const _pruneStubPrefix = '[pruned] tool_result ';

  void _archivePruned(String key, String content) {
    _pruneArchive[key] = content;
    while (_pruneArchive.length > maxArchivedToolResults) {
      _pruneArchive.remove(_pruneArchive.keys.first);
    }
  }

  /// Pesan yang berasal dari kompresi ini tidak boleh dianggap aturan agar
  /// tidak menumpuk tak terhingga lintas putaran kompresi.
  static const _summaryPrefix = 'Ringkasan percakapan sebelumnya:';

  /// Penanda pesan aturan/keamanan yang dipertahankan verbatim saat
  /// kompresi. Pencocokan case-insensitive pada awal tiap baris.
  static const _ruleLinePrefixes = <String>{
    '[rule]',
    '[rules]',
    '[safety]',
    '[aturan]',
    'safety rules',
    'aturan keamanan',
    'aturan mutlak',
    'must never',
    'must always',
    'jangan pernah',
    'harus selalu',
    'dilarang keras',
    'never execute',
    'jangan pernah mengeksekusi',
  };

  /// True bila pesan ini adalah pesan aturan/keamanan yang tidak boleh
  /// dipangkas atau diringkas (harus dipertahankan verbatim).
  static bool isRuleMessage(ChatMessage m) {
    if (m.role == 'system' && !m.content.startsWith(_summaryPrefix)) {
      return true;
    }
    for (final line in m.content.split('\n')) {
      final trimmed = line.trim().toLowerCase();
      for (final prefix in _ruleLinePrefixes) {
        if (trimmed.startsWith(prefix)) return true;
      }
    }
    return false;
  }

  /// Statistik kompresi terakhir (null bila belum ada yang dipangkas).
  CompactionStats? lastCompaction;

  Future<AgentContext> maybeCompact(
    AgentContext ctx, {
    LlmProvider? llmOverride,
    bool force = false,
  }) async {
    if (!enabled) return ctx;
    final chars = ctx.messages.fold<int>(0, (s, m) => s + m.content.length);
    final estTokensBefore = chars ~/ 4;
    // `force` (Hermes `conversation_compression_manual.py`): kompresi manual
    // /compact melewati ambang otomatis — user meminta, kompaksi jalan.
    if (!force && estTokensBefore < maxSoftTokens * thresholdRatio) return ctx;

    final messagesBefore = ctx.messages.length;

    // Type-aware retention (R2): pesan aturan/keamanan tidak pernah masuk
    // wilayah yang dipangkas. keepLastN hanya berlaku untuk pesan biasa.
    final trimmable = <ChatMessage>[];
    final rules = <ChatMessage>[];
    for (final m in ctx.messages) {
      final protected =
          isRuleMessage(m) || (preserve != null && preserve!(m));
      if (protected) {
        rules.add(m);
      } else {
        trimmable.add(m);
      }
    }
    final keep = trimmable.length <= keepLastN
        ? trimmable
        : trimmable.sublist(trimmable.length - keepLastN);
    final dropped = trimmable.length <= keepLastN
        ? <ChatMessage>[]
        : trimmable.sublist(0, trimmable.length - keepLastN);

    final summarizer = llmOverride ?? llm;
    // Sumber ringkasan hanya pesan yang benar-benar dibuang; pesan aturan
    // dipertahankan verbatim, bukan ditebak oleh peringkas.
    final summarySource = dropped.isEmpty ? trimmable : dropped;
    final summary = summarizer != null
        ? await _llmSummary(summarizer, summarySource)
        : _naiveSummary(summarySource);
    final retained = [...rules, ...keep];
    final estTokensAfter = summary.length ~/ 4 + _estTokens(retained);

    final compacted = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content: '$_summaryPrefix\n$summary',
      ),
      ...retained,
    ];

    final stats = CompactionStats(
      compacted: true,
      messagesBefore: messagesBefore,
      messagesAfter: compacted.length,
      estTokensBefore: estTokensBefore,
      estTokensAfter: estTokensAfter,
      usedLlm: summarizer != null,
      summary: summary,
      rulesRetained: rules.length,
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
