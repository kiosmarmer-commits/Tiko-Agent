import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.text, {this.shouldThrow = false});

  final String text;
  final bool shouldThrow;

  @override
  String get id => 'scripted';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (shouldThrow) throw StateError('down');
    if (text.isNotEmpty) yield LlmTextDelta(text);
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

AgentContext _ctx(List<ChatMessage> messages) => AgentContext(
      messages: messages,
      tools: const [],
      session: Session(id: 's', channel: 'cli', userKey: 'u'),
    );

void main() {
  group('Usage pricing (fase-7 C1/C2)', () {
    test('model dikenal → estimasi rate card status estimated', () {
      final est = estimateCostUsd(
        model: 'gpt-4o',
        promptTokens: 1_000_000,
        completionTokens: 500_000,
      );
      expect(est.status, costStatusEstimated);
      expect(est.usd, closeTo(2.50 + 5.00, 1e-9));
    });

    test('prefix + tanggal-suffix dikenali (gpt-4o-2024-08-06)', () {
      expect(pricingForModel('gpt-4o-2024-08-06'), isNotNull);
      final est = estimateCostUsd(
        model: 'gpt-4o-2024-08-06',
        promptTokens: 1_000_000,
        completionTokens: 0,
      );
      expect(est.status, costStatusEstimated);
      expect(est.usd, closeTo(2.50, 1e-9));
    });

    test('model tak dikenal / tanpa usage → status unknown, usd 0', () {
      final est = estimateCostUsd(
        model: 'model-rahasia-xyz',
        promptTokens: 100,
        completionTokens: 10,
      );
      expect(est.status, costStatusUnknown);
      expect(est.usd, 0);
      final empty = estimateCostUsd(model: 'gpt-4o', promptTokens: 0, completionTokens: 0);
      expect(empty.status, costStatusUnknown);
    });

    test('formatCostLabel: nol, sub-cent, dan normal (Hermes #79220)', () {
      expect(formatCostLabel(0), r'$0.00');
      expect(formatCostLabel(0.0046), '~\$0.0046');
      expect(formatCostLabel(0.000001), '~\$<0.0001');
      expect(formatCostLabel(1.234), '~\$1.23');
    });
  });

  group('CreditsTracker (fase-7 C1)', () {
    test('akumulasi + sisa kredit; tanpa limit → remaining null', () {
      final t = CreditsTracker(dailyLimitUsd: 10);
      t.recordCost(4);
      t.recordCost(3);
      expect(t.spentToday, closeTo(7, 1e-9));
      expect(t.remaining, closeTo(3, 1e-9));
      expect(t.exceeded, isFalse);
      expect(CreditsTracker().remaining, isNull);
    });

    test('limit terlampaui → exceeded; negatif/NaN diabaikan', () {
      final t = CreditsTracker(dailyLimitUsd: 5);
      t.recordCost(6);
      expect(t.exceeded, isTrue);
      expect(t.remaining, 0);
      t.recordCost(-1);
      t.recordCost(double.nan);
      expect(t.spentToday, closeTo(6, 1e-9));
    });

    test('sinyal peringatan sekali per hari di 80% limit', () {
      final t = CreditsTracker(dailyLimitUsd: 10, warnRatio: 0.8);
      t.recordCost(5);
      expect(t.consumeWarnSignal(), isFalse);
      t.recordCost(3.5);
      expect(t.consumeWarnSignal(), isTrue);
      expect(t.consumeWarnSignal(), isFalse, reason: 'sekali per hari');
    });

    test('rollover hari UTC me-reset pengeluaran', () {
      var day = '2026-01-01';
      final t = CreditsTracker(
        dailyLimitUsd: 10,
        dayKey: () => day,
      );
      t.recordCost(9);
      expect(t.exceeded, isFalse);
      day = '2026-01-02';
      expect(t.spentToday, 0);
      expect(t.exceeded, isFalse);
      expect(t.consumeWarnSignal(), isFalse);
    });
  });

  group('Title generator (fase-7 C3)', () {
    test('deriveTitle: instant deterministik + cap 48 char di batas kata',
        () {
      expect(deriveTitle('Halo, bagaimana cara deploy Flutter web?'),
          'Halo, bagaimana cara deploy Flutter web?');
      final long = deriveTitle(
          'Bantu saya merancang arsitektur microservices untuk sistem '
          'pembayaran skala besar dengan banyak kriteria tambahan panjang '
          'di baris pertama ini yang terus berlanjut');
      expect(long, isNotNull);
      expect(long!.length, lessThanOrEqualTo(48));
      expect(long.endsWith('microservices'), isTrue,
          reason: 'dipotong di batas kata, tanpa potongan tengah kata');
    });

    test('deriveTitle: strip heading markdown dan @-reference', () {
      expect(deriveTitle('## Judul Proyek'), 'Judul Proyek');
      expect(deriveTitle('lihat @file:src/main.dart untuk detail'),
          'lihat untuk detail');
    });

    test('isTitleableUserMessage: slash command & teks pendek ditolak', () {
      expect(isTitleableUserMessage('/compact'), isFalse);
      expect(isTitleableUserMessage('ok'), isFalse);
      expect(isTitleableUserMessage('tolong analisis kode ini'), isTrue);
    });

    test('upgradeTitleWithLlm: JSON title valid diterima', () async {
      final out = await upgradeTitleWithLlm(
        _ScriptedLlm('{"title": "Deploy Flutter Web"}'),
        'tolong bantu deploy aplikasi flutter ke web',
      );
      expect(out, 'Deploy Flutter Web');
    });

    test('upgradeTitleWithLlm: jawaban panjang (answer-shaped) ditolak',
        () async {
      final out = await upgradeTitleWithLlm(
        _ScriptedLlm(
            'Untuk melakukan deploy Flutter web, Anda dapat menjalankan '
            'flutter build lalu menyajikan folder build/web melalui server '
            'statis apa pun yang Anda miliki di lingkungan produksi.'),
        'cara deploy?',
      );
      expect(out, isNull);
    });

    test('upgradeTitleWithLlm: fallback teks polos; provider error → null',
        () async {
      expect(
        await upgradeTitleWithLlm(
            _ScriptedLlm('Deploy Flutter Web'), 'pesan pembuka'),
        'Deploy Flutter Web',
        reason: 'JSON korup → fallback ekstraksi teks polos',
      );
      expect(
        await upgradeTitleWithLlm(_ScriptedLlm('', shouldThrow: true), 'pesan'),
        isNull,
      );
    });

    test('titleRank: derived < llm < user', () {
      expect(titleRank('derived'), lessThan(titleRank('llm')));
      expect(titleRank('llm'), lessThan(titleRank('user')));
    });
  });

  group('Compaction events (fase-7 C4)', () {
    test('Compactor force manual → record committed kind summarize', () async {
      CompactionEvent? captured;
      final c = Compactor(keepLastN: 2, onCompactionEvent: (e) => captured = e);
      final ctx = _ctx([
        for (var i = 0; i < 6; i++)
          ChatMessage(role: 'user', content: 'pesan-$i ${'x' * 200}'),
      ]);
      await c.maybeCompact(ctx, force: true, trigger: 'manual');
      expect(captured, isNotNull);
      expect(captured!.kind, 'summarize');
      expect(captured!.trigger, 'manual');
      expect(captured!.triggerClass, 'manual');
      expect(captured!.outcome, 'committed');
      expect(captured!.messagesAfter, lessThan(6));
      final json = captured!.toJson();
      expect(json['schema'], 'hermes.compaction');
      expect(json['schema_version'], '1');
    });

    test('ambang tercapai tapi tidak ada yang dibuang → record skipped',
        () async {
      CompactionEvent? captured;
      final c = Compactor(
        maxSoftTokens: 100,
        keepLastN: 6,
        onCompactionEvent: (e) => captured = e,
      );
      final rules = [
        ChatMessage(role: 'system', content: 'RULE ${'y' * 400}'),
      ];
      final ctx = _ctx(rules);
      await c.maybeCompact(ctx);
      expect(captured, isNotNull);
      expect(captured!.outcome, 'skipped');
    });

    test('di bawah ambang tanpa force → tidak ada record (bukan attempt)',
        () async {
      CompactionEvent? captured;
      final c = Compactor(keepLastN: 2, onCompactionEvent: (e) => captured = e);
      final ctx = _ctx([
        const ChatMessage(role: 'user', content: 'pendek'),
      ]);
      await c.maybeCompact(ctx);
      expect(captured, isNull);
    });

    test('pruneToolResults → record prune_tool_results committed', () {
      CompactionEvent? captured;
      final c = Compactor(
        keepLastToolResults: 0,
        maxToolResultChars: 10,
        onCompactionEvent: (e) => captured = e,
      );
      final ctx = _ctx([
        ChatMessage(
          role: 'tool',
          content: 'z' * 100,
          toolCallId: 't1',
          name: 'tool_x',
        ),
      ]);
      final out = c.pruneToolResults(ctx);
      expect(out.messages.first.content, startsWith('[pruned]'));
      expect(captured, isNotNull);
      expect(captured!.kind, 'prune_tool_results');
      expect(captured!.method, 'deterministic_prune');
      expect(captured!.outcome, 'committed');
    });

    test('MicroCompactor pass menyerap → record micro_summarize committed',
        () async {
      CompactionEvent? captured;
      final c = MicroCompactor(enabled: true, onCompactionEvent: (e) => captured = e);
      final ctx = _ctx([
        const ChatMessage(role: 'user', content: 't1'),
        ChatMessage(role: 'assistant', content: 'a1 ${'x' * 400}'),
        const ChatMessage(role: 'user', content: 't2'),
        ChatMessage(role: 'assistant', content: 'a2 ${'x' * 400}'),
        const ChatMessage(role: 'user', content: 't3'),
        ChatMessage(role: 'assistant', content: 'a3 ${'x' * 400}'),
      ]);
      await c.maybeMicroCompact(ctx);
      expect(captured, isNotNull);
      expect(captured!.kind, 'micro_summarize');
      expect(captured!.outcome, 'committed');
      expect(captured!.messagesAfter, captured!.messagesBefore,
          reason: 'assistant lama digantikan marker 1:1 (user tidak pernah '
              'diserap)');
      expect(captured!.tokensAfter, lessThan(captured!.tokensBefore));
    });

    test('CompactionEventSink: ring buffer + never-raises', () {
      final sink = CompactionEventSink(capacity: 2);
      final ts = DateTime.now().toUtc();
      for (var i = 0; i < 5; i++) {
        sink.emit(CompactionEvent(
          kind: 'summarize',
          trigger: 'turn_start_threshold',
          method: 'deterministic_fallback',
          outcome: 'committed',
          tokensBefore: i,
          tokensAfter: i,
          messagesBefore: i,
          messagesAfter: i,
          durationMs: 0,
          ts: ts,
        ));
      }
      expect(sink.records.length, 2);
      expect(sink.records.last.tokensBefore, 4);
      expect(sink.toJson().length, 2);
    });
  });

  group('Compaction display (fase-7 C4)', () {
    test('marker dengan ringkasan → proyeksi berisi teks ringkasan', () {
      const marker = ChatMessage(
        role: 'system',
        content: '$microSummaryPrefix\n$microMarkerTag\nisi ringkasan',
      );
      final proj = projectCompactionMessageForDisplay(marker);
      expect(proj, isNotNull);
      expect(proj!.content, 'isi ringkasan');
      expect(isCompactionMessage(marker), isTrue);
    });

    test('compactionSummaryOf: strip prefix + tag micro', () {
      const marker = ChatMessage(
        role: 'system',
        content: '$microSummaryPrefix\n$microMarkerTag\n- keputusan A\n- path B',
      );
      final s = compactionSummaryOf(marker);
      expect(s, isNotNull);
      expect(s!['summary'], '- keputusan A\n- path B');
      expect(s['compacted_messages'], isNull);
    });

    test('pesan bukan kompresi → diteruskan utuh, bukan compaction', () {
      const m = ChatMessage(role: 'user', content: 'halo dunia yang panjang');
      expect(isCompactionMessage(m), isFalse);
      final proj = projectCompactionMessageForDisplay(m);
      expect(proj, isNotNull);
      expect(proj!.content, 'halo dunia yang panjang');
      expect(compactionSummaryOf(m), isNull);
    });
  });
}
