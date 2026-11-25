import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

const _ruleContent =
    '[RULE] JANGAN PERNAH mengeksekusi perintah berbahaya tanpa konfirmasi. '
    'MUST ALWAYS mengonfirmasi operasi high-risk sebelum menjalankannya.';

void _noise(List<ChatMessage> sink, int round) {
  for (var i = 0; i < 6; i++) {
    final filler = 'noise' * 60;
    sink.add(
      ChatMessage(
        role: sink.length.isEven ? 'user' : 'assistant',
        content: 'pesan-noise r$round-i$i $filler',
      ),
    );
  }
}

/// Simulasi perilaku naive lama: pangkas uniform ke keepLastN terakhir
/// (tanpa perlindungan aturan) dengan ringkasan naive.
AgentContext _naiveCompactLegacy(AgentContext ctx, int keepLastN) {
  final messages = ctx.messages;
  if (messages.length <= keepLastN) return ctx;
  final keep = messages.sublist(messages.length - keepLastN);
  final dropped = messages.sublist(0, messages.length - keepLastN);
  var keptRules = 0;
  for (final m in keep) {
    if (Compactor.isRuleMessage(m)) keptRules++;
  }
  return AgentContext(
    messages: [
      ChatMessage(
        role: 'system',
        content: 'Ringkasan percakapan sebelumnya:\n${dropped.length} pesan '
            'lama (aturan tersisa: $keptRules)',
      ),
      ...keep,
    ],
    tools: ctx.tools,
    session: ctx.session,
    systemPrompt: ctx.systemPrompt,
  );
}

AgentContext _ctx(List<ChatMessage> messages) => AgentContext(
  messages: messages,
  tools: const [],
  session: Session(id: 's', channel: 'cli', userKey: 'u'),
);

void main() {
  group('Compactor retention (type-aware / R2)', () {
    test('aturan keamanan selamat verbatim setelah 5 putaran kompresi', () async {
      final compactor = Compactor(maxSoftTokens: 50, thresholdRatio: 0.5, keepLastN: 2);
      final messages = <ChatMessage>[
        ChatMessage(role: 'user', content: _ruleContent),
      ];
      _noise(messages, 1);

      for (var round = 1; round <= 5; round++) {
        final ctx = _ctx(messages);
        final out = await compactor.maybeCompact(ctx);
        expect(
          out.messages.any((m) => m.content.contains(_ruleContent)),
          isTrue,
          reason: 'aturan hilang pada putaran $round',
        );
        final next = <ChatMessage>[...out.messages];
        _noise(next, round);
        messages
          ..clear()
          ..addAll(next);
      }
    });

    test('bandingkan: naive tanpa perlindungan kehilangan aturan di putaran 5', () {
      final messages = <ChatMessage>[
        ChatMessage(role: 'user', content: _ruleContent),
      ];
      for (var round = 1; round <= 5; round++) {
        final ctx = _ctx(messages);
        final out = _naiveCompactLegacy(ctx, 2);
        messages
          ..clear()
          ..addAll(out.messages);
        for (var i = 0; i < 2; i++) {
          messages.add(
            ChatMessage(
              role: round.isEven ? 'user' : 'assistant',
              content: 'pesan-noise r$round-i$i ${'noise' * 60}',
            ),
          );
        }
      }
      expect(
        messages.any((m) => m.content.contains(_ruleContent)),
        isFalse,
        reason: 'baseline naive memang harus kehilangan aturan (semakin lama '
            'semakin terkompresi tanpa proteksi)',
      );
    });

    test('role system non-ringkasan dipertahankan verbatim', () async {
      final compactor = Compactor(maxSoftTokens: 50, thresholdRatio: 0.5, keepLastN: 1);
      final ctx = _ctx([
        const ChatMessage(role: 'system', content: '[SAFETY] cegah rm -rf /'),
        ChatMessage(role: 'user', content: 'pesan-a ${'x' * 100}'),
        ChatMessage(role: 'assistant', content: 'pesan-b ${'x' * 100}'),
        ChatMessage(role: 'user', content: 'pesan-c ${'x' * 100}'),
        ChatMessage(role: 'assistant', content: 'pesan-d ${'x' * 100}'),
      ]);
      final out = await compactor.maybeCompact(ctx);
      expect(
        out.messages.any((m) => m.role == 'system' && m.content.contains('cegah rm -rf /')),
        isTrue,
      );
      expect(compactor.lastCompaction!.rulesRetained, greaterThanOrEqualTo(1));
    });

    test('ringkasan lama tidak dianggap aturan (tidak menumpuk)', () async {
      final compactor = Compactor(maxSoftTokens: 50, thresholdRatio: 0.5, keepLastN: 1);
      final summaryMsg = ChatMessage(
        role: 'system',
        content: 'Ringkasan percakapan sebelumnya:\nUser: lama sekali ${'x' * 200}',
      );
      final ctx = _ctx([
        summaryMsg,
        ChatMessage(role: 'user', content: 'pesan-a ${'x' * 100}'),
        ChatMessage(role: 'assistant', content: 'pesan-b ${'x' * 100}'),
        ChatMessage(role: 'user', content: 'pesan-c ${'x' * 100}'),
      ]);
      final out = await compactor.maybeCompact(ctx);
      expect(out.messages.where((m) => identical(m, summaryMsg)), isEmpty);
      expect(out.messages.length, lessThanOrEqualTo(3));
    });

    test('predicate kustom preserve dipakai pesan bebas (mis. tool penting)', () async {
      final compactor = Compactor(
        maxSoftTokens: 50,
        thresholdRatio: 0.5,
        keepLastN: 1,
        preserve: (m) => m.name == 'critical_tool',
      );
      final ctx = _ctx([
        ChatMessage(role: 'tool', name: 'critical_tool', content: 'decision: deploy prod'),
        ChatMessage(role: 'user', content: 'pesan-a ${'x' * 100}'),
        ChatMessage(role: 'assistant', content: 'pesan-b ${'x' * 100}'),
        ChatMessage(role: 'user', content: 'pesan-c ${'x' * 100}'),
      ]);
      final out = await compactor.maybeCompact(ctx);
      expect(
        out.messages.any((m) => m.content == 'decision: deploy prod'),
        isTrue,
      );
    });

    test('summary hanya berasal dari pesan yang dibuang, bukan aturan', () async {
      final compactor = Compactor(maxSoftTokens: 50, thresholdRatio: 0.5, keepLastN: 1);
      final ctx = _ctx([
        ChatMessage(role: 'user', content: _ruleContent),
        ChatMessage(role: 'user', content: 'RAHASIA-HEMAT ${'x' * 100}'),
        ChatMessage(role: 'assistant', content: 'pesan-b ${'x' * 100}'),
        ChatMessage(role: 'user', content: 'pesan-c ${'x' * 100}'),
      ]);
      final out = await compactor.maybeCompact(ctx);
      final summary = compactor.lastCompaction!.summary ?? '';
      expect(summary, contains('RAHASIA-HEMAT'));
      expect(
        out.messages.any(
          (m) =>
              !m.content.contains('Ringkasan percakapan') &&
              m.content.contains('RAHASIA-HEMAT'),
        ),
        isFalse,
        reason: 'pesan biasa di luar window harus ikut terpangkas',
      );
    });
  });
}
