import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _ScriptedMerge implements LlmProvider {
  _ScriptedMerge(this.text, {this.finish = 'stop', this.shouldThrow = false});

  final String text;
  final String finish;
  final bool shouldThrow;
  int requests = 0;

  @override
  String get id => 'merge-mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    requests++;
    if (shouldThrow) throw StateError('provider down');
    if (text.isNotEmpty) yield LlmTextDelta(text);
    yield LlmDone(finishReason: finish);
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

AgentContext _ctx(List<ChatMessage> messages) {
  return AgentContext(
    messages: messages,
    tools: const [],
    session: Session(id: 's', channel: 'cli', userKey: 'u'),
  );
}

/// Dua exchange lengkap lama + dua user turn terakhir panas.
List<ChatMessage> _hotTailMessages() => [
      const ChatMessage(role: 'user', content: 'tanya-1'),
      const ChatMessage(role: 'assistant', content: 'jawab-1'),
      const ChatMessage(role: 'user', content: 'tanya-2'),
      const ChatMessage(role: 'assistant', content: 'jawab-2'),
      const ChatMessage(role: 'user', content: 'tanya-3'),
      const ChatMessage(role: 'assistant', content: 'jawab-3'),
    ];

void main() {
  group('MicroCompactor', () {
    test('disabled (default Hermes) → ctx dilewati tanpa diubah', () async {
      final c = MicroCompactor();
      final ctx = _ctx(_hotTailMessages());
      final out = await c.maybeMicroCompact(ctx);
      expect(identical(out, ctx), isTrue);
      expect(c.last, isNull);
    });

    test('naive merge: exchange lama diserap, tail panas + user verbatim',
        () async {
      final c = MicroCompactor(enabled: true, keepLastExchanges: 2);
      final ctx = _ctx(_hotTailMessages());
      final out = await c.maybeMicroCompact(ctx);
      expect(c.last, isNotNull);
      expect(c.last!.absorbedExchanges, 1,
          reason: 'satu exchange (user1/assistant1) berada di wilayah serap');
      expect(out.messages.length, ctx.messages.length,
          reason: 'assistant lama digantikan marker 1:1, user tetap');
      expect(out.messages[0].content, 'tanya-1',
          reason: 'pesan user tidak pernah diserap');
      expect(out.messages[1].role, 'system',
          reason: 'marker menggantikan assistant lama yang diserap');
      final marker = out.messages[1];
      expect(marker.content, contains(microMarkerTag));
      expect(marker.content, contains('jawab-1'));
      expect(out.messages.last.content, 'jawab-3',
          reason: 'tail panas tidak tersentuh');
      expect(out.session.summary, isNotEmpty);
    });

    test('messages pendek (≤ keepLast*2+1) → tidak ada pass', () async {
      final c = MicroCompactor(enabled: true, keepLastExchanges: 2);
      final ctx = _ctx([
        const ChatMessage(role: 'user', content: 'u'),
        const ChatMessage(role: 'assistant', content: 'a'),
        const ChatMessage(role: 'user', content: 'u2'),
        const ChatMessage(role: 'assistant', content: 'a2'),
        const ChatMessage(role: 'user', content: 'u3'),
      ]);
      final out = await c.maybeMicroCompact(ctx);
      expect(identical(out, ctx), isTrue);
      expect(c.last, isNull);
    });

    test('LLM merge sukses → ringkasan bergulir dari provider, think di-strip',
        () async {
      final llm = _ScriptedMerge(
          '<think> draft internal </think> ringkasan final rapi');
      final c = MicroCompactor(enabled: true);
      final ctx = _ctx(_hotTailMessages());
      final out = await c.maybeMicroCompact(ctx, summarizer: llm);
      expect(c.last!.usedLlm, isTrue);
      expect(c.rollingSummary, 'ringkasan final rapi');
      expect(c.rollingSummary, isNot(contains('draft')));
      expect(out.messages.any((m) => m.content.contains('ringkasan final')),
          isTrue);
    });

    test('LLM finishReason length → merge dibuang, exchange tidak diserap',
        () async {
      final llm = _ScriptedMerge('parsial', finish: 'length');
      final c = MicroCompactor(enabled: true);
      final ctx = _ctx(_hotTailMessages());
      final out = await c.maybeMicroCompact(ctx, summarizer: llm);
      expect(identical(out, ctx), isTrue,
          reason: 'merge parsial dibuang, exchange dibiarkan untuk pass '
              'berikutnya');
      expect(c.last, isNull);
      expect(c.rollingSummary, isEmpty);
    });

    test('LLM melempar exception → fail-open, exchange tidak diserap',
        () async {
      final llm = _ScriptedMerge('x', shouldThrow: true);
      final c = MicroCompactor(enabled: true);
      final ctx = _ctx(_hotTailMessages());
      final out = await c.maybeMicroCompact(ctx, summarizer: llm);
      expect(identical(out, ctx), isTrue);
    });

    test('summaryFromMarker: rehydrate ringkasan dari marker transcript',
        () {
      final marker = ChatMessage(
        role: 'system',
        content: '$microSummaryPrefix\n$microMarkerTag\nisi ringkasan',
      );
      expect(MicroCompactor.summaryFromMarker(marker), 'isi ringkasan');
      expect(
        MicroCompactor.summaryFromMarker(const ChatMessage(
          role: 'user',
          content: 'teks biasa',
        )),
        '',
      );
    });

    test('pass kedua: cursor maju, defrag memicu re-summarize saat ambang',
        () async {
      final llm = _ScriptedMerge('RINGKASAN-DEFRAG');
      final c = MicroCompactor(
        enabled: true,
        keepLastExchanges: 1,
        defragThresholdTokens: 1,
      );
      var ctx = _ctx(_hotTailMessages());
      ctx = await c.maybeMicroCompact(ctx, summarizer: llm);
      expect(c.last!.defragged, isFalse);
      final markerAfter1 = ctx.messages
          .firstWhere((m) => m.content.startsWith(microSummaryPrefix));

      // Pass kedua: rolling ≥ ambang → defrag (re-summarize) berjalan;
      // wilayah serap sudah habis → tidak ada absorpsi baru (fail-open).
      final out2 = await c.maybeMicroCompact(ctx, summarizer: llm);
      expect(c.rollingSummary, 'RINGKASAN-DEFRAG',
          reason: 'defrag me-re-summarize ringkasan bergulir');
      expect(llm.requests, greaterThanOrEqualTo(2),
          reason: 'merge pass-1 + defrag pass-2');
      expect(out2.messages.length, ctx.messages.length);
      expect(
        out2.messages
            .where((m) => m.content.startsWith(microSummaryPrefix))
            .length,
        1,
      );
      // Marker lama tidak ditulis ulang saat tidak ada absorpsi.
      expect(
        out2.messages.firstWhere((m) => m.content.startsWith(microSummaryPrefix))
            .content,
        markerAfter1.content,
      );
    });
  });

  group('OutputBudgetTimeout', () {
    test('outputBudgetHops: null/nol/negatif/non-int → 1 hop', () {
      expect(outputBudgetHops(null), 1);
      expect(outputBudgetHops(0), 1);
      expect(outputBudgetHops(-5), 1);
      expect(outputBudgetHops('bukan int'), 1);
    });

    test('outputBudgetHops: ceiling division terhadap 32768', () {
      expect(outputBudgetHops(100), 1);
      expect(outputBudgetHops(outputBudgetHopTokens), 1);
      expect(outputBudgetHops(outputBudgetHopTokens + 1), 2);
      expect(outputBudgetHops(outputBudgetHopTokens * 2), 2);
      expect(outputBudgetHops(outputBudgetHopTokens * 2 + 1), 3);
    });
  });

  group('StreamLifetime', () {
    test('resolveStreamMaxLifetime: off bila null/≤0/non-finite', () {
      expect(resolveStreamMaxLifetime(null, null), 0.0);
      expect(resolveStreamMaxLifetime(0, null), 0.0);
      expect(resolveStreamMaxLifetime(-3, null), 0.0);
      expect(resolveStreamMaxLifetime(double.infinity, null), 0.0);
      expect(resolveStreamMaxLifetime(double.nan, null), 0.0);
    });

    test('resolveStreamMaxLifetime: difloor (dibatasi minimal) oleh stale '
        'timeout finite', () {
      expect(resolveStreamMaxLifetime(30, 60), 60.0,
          reason: 'cap tak boleh lebih kecil dari stale timeout');
      expect(resolveStreamMaxLifetime(120, 60), 120.0);
      expect(resolveStreamMaxLifetime(30, double.nan), 30.0);
    });

    test('cap 0 → never exceeded', () {
      final lt = StreamLifetime(cap: 0, clock: () => 1e9);
      expect(lt.exceeded(0), isNull);
    });

    test('melewati cap → elapsed dikembalikan dan timer di-reset', () {
      var now = 0.0;
      final lt = StreamLifetime(cap: 5, clock: () => now);
      expect(lt.exceeded(0), isNull, reason: 'attempt baru me-restart timer');
      now = 3;
      expect(lt.exceeded(0), isNull);
      now = 6;
      final exceeded = lt.exceeded(0);
      expect(exceeded, isNotNull);
      expect(exceeded! >= 5, isTrue);
      now = 7;
      expect(lt.exceeded(0), isNull,
          reason: 'timer sudah di-reset pada kill');
    });

    test('attempt berbeda me-restart pengukuran (cap penuh per retry)', () {
      var now = 0.0;
      final lt = StreamLifetime(cap: 5, clock: () => now);
      expect(lt.exceeded(0), isNull);
      now = 10;
      expect(lt.exceeded(1), isNull);
    });

    test('pesan exceeded menyebut setting dan cap', () {
      final msg = streamLifetimeExceededMessage(90, 60.0);
      expect(msg, contains('stream_max_lifetime'));
      expect(msg, contains('60'));
    });
  });

  group('AgentConfig fase-6 defaults (OFF per Hermes)', () {
    test('microCompaction dan streamMaxLifetimeSec default mati', () {
      const cfg = AgentConfig();
      expect(cfg.microCompaction, isFalse);
      expect(cfg.microCompactionKeepLastExchanges, 2);
      expect(cfg.streamMaxLifetimeSec, 0);
    });
  });
}
