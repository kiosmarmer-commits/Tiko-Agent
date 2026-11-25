import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

class _EchoSummaryProvider implements LlmProvider {
  _EchoSummaryProvider(this.text, {this.shouldThrow = false});

  final String text;
  final bool shouldThrow;
  int requests = 0;

  @override
  String get id => 'echo-summary';

  @override
  Capabilities get capabilities => const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    requests++;
    if (shouldThrow) {
      throw StateError('provider down');
    }
    yield LlmTextDelta(text);
    yield const LlmDone();
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

AgentContext _ctxWithMessages(int totalMessages, {int fillerChars = 200}) {
  final messages = <ChatMessage>[];
  for (var i = 0; i < totalMessages; i++) {
    messages.add(
      ChatMessage(
        role: i.isEven ? 'user' : 'assistant',
        content: 'pesan-$i ${'x' * fillerChars}',
      ),
    );
  }
  return AgentContext(
    messages: messages,
    tools: const [],
    session: Session(id: 's', channel: 'cli', userKey: 'u'),
  );
}

void main() {
  group('Compactor (ALG-05) kompresi konteks', () {
    test('di bawah ambang ctx dilewati tanpa perubahan', () async {
      final compactor = Compactor(maxSoftTokens: 6000);
      final ctx = _ctxWithMessages(4);
      final out = await compactor.maybeCompact(ctx);
      expect(identical(out, ctx), isTrue);
      expect(compactor.lastCompaction, isNull);
    });

    test(
      'di atas ambang kompresi naive memangkas riwayat + set summary',
      () async {
        final compactor = Compactor(
          maxSoftTokens: 100,
          thresholdRatio: 0.5,
          keepLastN: 3,
        );
        final ctx = _ctxWithMessages(10, fillerChars: 500);
        final out = await compactor.maybeCompact(ctx);
        expect(out.messages.length, 4);
        expect(out.messages.first.role, 'system');
        expect(out.messages.first.content, contains('Ringkasan percakapan'));
        expect(out.session.summary, isNotNull);
        expect(out.messages.sublist(1), ctx.messages.sublist(7));
        expect(out.recentToolCalls, ctx.recentToolCalls);
        final stats = compactor.lastCompaction!;
        expect(stats.compacted, isTrue);
        expect(stats.usedLlm, isFalse);
        expect(stats.messagesBefore, 10);
        expect(stats.messagesAfter, 4);
        expect(stats.estTokensAfter, lessThan(stats.estTokensBefore));
      },
    );

    test(
      'llmOverride dipakai sebagai peringkas dan tercatat di stats',
      () async {
        final summarizer = _EchoSummaryProvider('RINGKASAN-LA-VERITAS');
        final compactor = Compactor(
          maxSoftTokens: 100,
          thresholdRatio: 0.5,
          keepLastN: 2,
        );
        final ctx = _ctxWithMessages(8, fillerChars: 500);
        final out = await compactor.maybeCompact(ctx, llmOverride: summarizer);
        expect(summarizer.requests, 1);
        expect(out.session.summary, 'RINGKASAN-LA-VERITAS');
        expect(out.messages.first.content, contains('RINGKASAN-LA-VERITAS'));
        expect(compactor.lastCompaction!.usedLlm, isTrue);
      },
    );

    test('kegagalan LLM fallback ke heuristic naive tanpa error', () async {
      final summarizer = _EchoSummaryProvider('', shouldThrow: true);
      final compactor = Compactor(
        maxSoftTokens: 100,
        thresholdRatio: 0.5,
        keepLastN: 2,
      );
      final ctx = _ctxWithMessages(6, fillerChars: 500);
      final out = await compactor.maybeCompact(ctx, llmOverride: summarizer);
      expect(out.messages.length, 3);
      expect(out.messages.first.content, contains('User: pesan-'));
      expect(compactor.lastCompaction!.usedLlm, isTrue);
    });

    test('disabled mematikan kompresi penuh', () async {
      var called = 0;
      final compactor = Compactor(
        enabled: false,
        maxSoftTokens: 1,
        thresholdRatio: 1.0,
        onCompaction: (_) => called++,
      );
      final ctx = _ctxWithMessages(6, fillerChars: 500);
      final out = await compactor.maybeCompact(ctx);
      expect(identical(out, ctx), isTrue);
      expect(compactor.lastCompaction, isNull);
      expect(called, 0);
    });

    test('onCompaction dipanggil dengan stats saat kompresi terjadi', () async {
      final events = <CompactionStats>[];
      final compactor = Compactor(
        maxSoftTokens: 100,
        thresholdRatio: 0.5,
        keepLastN: 2,
        onCompaction: events.add,
      );
      final ctx = _ctxWithMessages(6, fillerChars: 500);
      await compactor.maybeCompact(ctx);
      expect(events.length, 1);
      expect(events.first.compacted, isTrue);
      expect(events.first.toJson()['used_llm'], isFalse);
    });

    test(
      'callback onCompaction yang melempar tidak merusak kompresi',
      () async {
        final compactor = Compactor(
          maxSoftTokens: 100,
          thresholdRatio: 0.5,
          keepLastN: 2,
          onCompaction: (_) => throw StateError('listener mogok'),
        );
        final ctx = _ctxWithMessages(6, fillerChars: 500);
        final out = await compactor.maybeCompact(ctx);
        expect(out.messages.length, 3);
        expect(compactor.lastCompaction!.compacted, isTrue);
      },
    );
  });
}
