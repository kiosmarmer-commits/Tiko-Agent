import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('SideQuestionLease', () {
    test('acquire → held; release pemegang sama → lepas', () {
      final lease = SideQuestionLease();
      var now = 1000.0;
      double clock() => now;
      expect(lease.isHeld('s1', clock: clock), isFalse);
      expect(
        lease.tryAcquire('s1', owner: 'a', clock: clock),
        isTrue,
      );
      expect(lease.isHeld('s1', clock: clock), isTrue);
      expect(
        lease.tryAcquire('s1', owner: 'b', clock: clock),
        isFalse,
        reason: 'sudah dipegang pemegang hidup lain',
      );
      expect(lease.release('s1', owner: 'b'), isFalse,
          reason: 'bukan pemegangnya');
      expect(lease.release('s1', owner: 'a'), isTrue);
      expect(lease.isHeld('s1', clock: clock), isFalse);
    });

    test('TTL kedaluwarsa → lease yatim tidak mengunci selamanya', () {
      final lease = SideQuestionLease(defaultTtlSec: 60);
      var now = 1000.0;
      double clock() => now;
      lease.tryAcquire('s1', owner: 'a', clock: clock);
      now += 61;
      expect(lease.isHeld('s1', clock: clock), isFalse);
      expect(lease.tryAcquire('s1', owner: 'b', clock: clock), isTrue);
    });

    test('sweep membuang lease kedaluwarsa dan melaporkan jumlahnya', () {
      final lease = SideQuestionLease(defaultTtlSec: 10);
      var now = 0.0;
      double clock() => now;
      lease.tryAcquire('s1', owner: 'a', clock: clock);
      lease.tryAcquire('s2', owner: 'a', clock: clock);
      now += 11;
      lease.tryAcquire('s3', owner: 'a', clock: clock);
      expect(lease.sweep(clock: clock), 2);
      expect(lease.isHeld('s3', clock: clock), isTrue);
    });

    test('ttlSec di luar rentang di-clamp 1..3600', () {
      final lease = SideQuestionLease();
      var now = 0.0;
      double clock() => now;
      lease.tryAcquire('s1', owner: 'a', clock: clock, ttlSec: 0);
      now += 2;
      expect(lease.isHeld('s1', clock: clock), isFalse,
          reason: 'ttl 0 di-clamp ke 1 detik');
    });
  });

  group('Compactor force (kompresi manual /compact)', () {
    AgentContext _ctx(List<String> texts) {
      return AgentContext(
        messages: [
          for (final t in texts) ChatMessage(role: 'user', content: t),
        ],
        tools: const [],
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
      );
    }

    test('di bawah ambang tanpa force → tidak dikompres', () async {
      final c = Compactor(keepLastN: 2);
      final ctx = _ctx(List.generate(6, (i) => 'pesan pendek $i'));
      final out = await c.maybeCompact(ctx);
      expect(c.lastCompaction, isNull);
      expect(out.messages.length, 6);
    });

    test('force → dikompres meski di bawah ambang', () async {
      final c = Compactor(keepLastN: 2);
      final ctx = _ctx(List.generate(6, (i) => 'pesan pendek $i'));
      final out = await c.maybeCompact(ctx, force: true);
      expect(c.lastCompaction, isNotNull);
      expect(c.lastCompaction!.compacted, isTrue);
      expect(out.messages.length, 3,
          reason: '1 pesan ringkasan + keepLastN 2');
      expect(out.messages.first.role, 'system');
      expect(out.messages.first.content,
          startsWith('Ringkasan percakapan sebelumnya:'));
      expect(out.session.summary, isNotNull);
    });

    test('pesan aturan dipertahankan verbatim saat force', () async {
      final c = Compactor(keepLastN: 2);
      final ctx = AgentContext(
        messages: [
          const ChatMessage(role: 'system', content: '[rule] jangan pernah'),
          ...List.generate(5, (i) => ChatMessage(role: 'user', content: 'm$i')),
        ],
        tools: const [],
        session: Session(id: 's', channel: 'cli', userKey: 'u'),
      );
      final out = await c.maybeCompact(ctx, force: true);
      expect(out.messages.first.role, 'system',
          reason: 'ringkasan selalu paling depan');
      expect(out.messages[1].content, '[rule] jangan pernah',
          reason: 'pesan aturan dipertahankan verbatim setelah ringkasan');
      expect(out.messages.where((m) => m.content == '[rule] jangan pernah'),
          hasLength(1));
    });
  });

  group('Agent loop — runaway stream watch', () {
    test('stream delta degenerasi → jawaban diganti pesan interupsi',
        () async {
      final replies = <String>[];
      var forwarded = 0;
      final provider = _RepeatStreamLlm();
      final router = Router(
        providers: {'mock': provider},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
        onTextDelta: (_) => forwarded++,
      );
      await loop.handle(
        InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(provider.turns, 1);
      expect(replies.last, repetitionLoopInterrupted);
      expect(loop.lastTurnEndReason, 'repetition_loop');
      expect(loop.lastAnswer, repetitionLoopInterrupted);
    });

    test('output panjang batch-like (baris berkounter) TIDAK diinterupsi',
        () async {
      final replies = <String>[];
      final provider = _BatchStreamLlm();
      final router = Router(
        providers: {'mock': provider},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
      );
      await loop.handle(
        InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(loop.lastTurnEndReason, 'completed');
      expect(replies.last, contains('row-'));
    });
  });
}

/// Provider yang men-stream satu blok teks identik berulang (loop degenerate)
/// hingga jauh melewati ambil 16k char.
class _RepeatStreamLlm implements LlmProvider {
  int turns = 0;

  @override
  String get id => 'mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    turns++;
    final chunk = '${'a' * 100}\n';
    for (var i = 0; i < 20; i++) {
      yield LlmTextDelta(chunk * 100);
    }
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

/// Provider yang men-stream baris "batch-like" dengan counter naik — meniru
/// laporan proses sah yang panjang, bukan loop degenerate.
class _BatchStreamLlm implements LlmProvider {
  int turns = 0;

  @override
  String get id => 'mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    turns++;
    for (var i = 0; i < 1200; i++) {
      yield LlmTextDelta('row-$i: ${'x' * 60}\n');
    }
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}
