import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('IterationBudget (Hermes iteration_budget)', () {
    test('consume sampai cap → false; refund mengembalikan slot', () {
      final b = IterationBudget(maxTotal: 2);
      expect(b.consume(), isTrue);
      expect(b.consume(), isTrue);
      expect(b.consume(), isFalse);
      expect(b.remaining, 0);
      b.refund();
      expect(b.remaining, 1);
      expect(b.used, 1);
      expect(b.consume(), isTrue);
    });

    test('refund tidak pernah negatif', () {
      final b = IterationBudget(maxTotal: 3);
      b.refund();
      expect(b.used, 0);
      expect(b.remaining, 3);
    });

    test('nearLimit dengan warnRatio; null = off', () {
      final b = IterationBudget(maxTotal: 10, warnRatio: 0.8);
      expect(b.nearLimit, isFalse);
      for (var i = 0; i < 7; i++) {
        b.consume();
      }
      // remaining = 3 <= floor(10*0.8)=8 → nearLimit.
      expect(b.nearLimit, isTrue);
      final off = IterationBudget(maxTotal: 10);
      off.consume();
      expect(off.nearLimit, isFalse);
    });

    test('normalizeIterationWarnRatio hanya (0,1) finite yang valid', () {
      expect(normalizeIterationWarnRatio(0.8), 0.8);
      expect(normalizeIterationWarnRatio('0.5'), 0.5);
      expect(normalizeIterationWarnRatio(0), isNull);
      expect(normalizeIterationWarnRatio(1), isNull);
      expect(normalizeIterationWarnRatio(-0.5), isNull);
      expect(normalizeIterationWarnRatio(true), isNull);
      expect(normalizeIterationWarnRatio('abc'), isNull);
      expect(normalizeIterationWarnRatio(double.nan), isNull);
      expect(normalizeIterationWarnRatio(double.infinity), isNull);
      expect(normalizeIterationWarnRatio(null), isNull);
    });
  });

  group('Turn liveness (Hermes turn_liveness)', () {
    test('ActivityClock: stamp menaikkan generation; revalidate menyaring',
        () {
      final clock = ActivityClock();
      final s0 = clock.sample();
      expect(s0.activityTs, isNull);
      clock.stamp('tool');
      final s1 = clock.sample();
      expect(s1.generation, 1);
      expect(s1.activityTs, isNotNull);
      expect(s1.idleSeconds, lessThan(5));
      expect(clock.revalidate(s1), isTrue);
      clock.stamp();
      expect(clock.revalidate(s1), isFalse,
          reason: 'generation baru membuat snapshot lama basi');
    });

    test('watchdog meng-abort saat idle > timeout', () async {
      final clock = ActivityClock();
      clock.stamp();
      var commitCalled = false;
      final wd = TurnLivenessWatchdog(
        clock: clock,
        timeoutS: 0.05,
        pollS: 0.02,
        isTurnActive: () => true,
        commitAbort: (snapshot, message) {
          commitCalled = true;
          return true;
        },
      );
      wd.start();
      addTearDown(wd.stop);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(commitCalled, isTrue);
      expect(wd.aborted, isTrue);
    });

    test('commit veto (turn bangun kembali) → tidak abort', () async {
      final clock = ActivityClock();
      clock.stamp();
      final wd = TurnLivenessWatchdog(
        clock: clock,
        timeoutS: 0.05,
        pollS: 0.02,
        isTurnActive: () => true,
        commitAbort: (snapshot, message) => false,
      );
      wd.start();
      addTearDown(wd.stop);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(wd.aborted, isFalse);
    });

    test('isTurnActive false → watchdog berhenti tanpa abort', () async {
      final clock = ActivityClock();
      clock.stamp();
      final wd = TurnLivenessWatchdog(
        clock: clock,
        timeoutS: 0.03,
        pollS: 0.02,
        isTurnActive: () => false,
        commitAbort: (snapshot, message) => true,
      );
      wd.start();
      addTearDown(wd.stop);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(wd.aborted, isFalse);
    });

    test('resolveTurnLivenessSettings: default, valid, NaN, off', () {
      final d = resolveTurnLivenessSettings(null);
      expect(d.timeoutS, defaultTurnLivenessTimeoutS);
      expect(d.pollS, defaultTurnLivenessPollS);
      expect(d.enabled, isTrue);

      final custom = resolveTurnLivenessSettings(const {
        'agent': {
          'turn_liveness': {'timeout_s': 30, 'poll_s': 1},
        },
      });
      expect(custom.timeoutS, 30);
      expect(custom.pollS, 1);

      final nan = resolveTurnLivenessSettings(const {
        'agent': {
          'turn_liveness': {'timeout_s': 'typo', 'poll_s': -5},
        },
      });
      expect(nan.timeoutS, defaultTurnLivenessTimeoutS);
      expect(nan.pollS, defaultTurnLivenessPollS);

      final off = resolveTurnLivenessSettings(const {
        'agent': {
          'turn_liveness': {'timeout_s': 0},
        },
      });
      expect(off.enabled, isFalse);
    });
  });

  group('Transcript repair (Hermes transcript_repair, adaptasi)', () {
    test('orphan tool result dibuang', () {
      final repaired = repairTranscript([
        const ChatMessage(role: 'user', content: 'hi'),
        const ChatMessage(
          role: 'tool',
          content: 'hasil yatim',
          toolCallId: 'call-x',
          name: 'read_file',
        ),
        const ChatMessage(role: 'assistant', content: 'jawaban'),
      ]);
      expect(repaired, hasLength(2));
      expect(repaired.any((m) => m.role == 'tool'), isFalse);
    });

    test('unpaired tool call dibuang; pasangan utuh dipertahankan', () {
      final repaired = repairTranscript([
        const ChatMessage(role: 'user', content: 'kerjakan'),
        const ChatMessage(
          role: 'assistant',
          content: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'read_file', args: {'path': 'a'}),
            ToolCall(id: 'c2', name: 'write_file', args: {'path': 'b'}),
          ],
        ),
        const ChatMessage(
          role: 'tool',
          content: 'isi a',
          toolCallId: 'c1',
          name: 'read_file',
        ),
        const ChatMessage(role: 'assistant', content: 'selesai'),
      ]);
      expect(repaired, hasLength(4));
      final assistant = repaired[1];
      expect(assistant.toolCalls, hasLength(1));
      expect(assistant.toolCalls!.single.id, 'c1');
      expect(repaired.any((m) => m.toolCallId == 'c2'), isFalse);
    });

    test('pesan plain kosong dibuang; transcript valid utuh', () {
      final valid = [
        const ChatMessage(role: 'user', content: 'halo'),
        const ChatMessage(role: 'assistant', content: 'hai!'),
      ];
      final repaired = repairTranscript([
        ...valid,
        const ChatMessage(role: 'assistant', content: ''),
      ]);
      expect(repaired, hasLength(2));
      expect(repairTranscript(valid), hasLength(2));
    });

    test('asisten hanya tool-call tanpa hasil & tanpa teks dibuang', () {
      final repaired = repairTranscript([
        const ChatMessage(role: 'user', content: 'go'),
        const ChatMessage(
          role: 'assistant',
          content: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'read_file', args: {}),
          ],
        ),
      ]);
      expect(repaired, hasLength(1));
    });
  });

  group('PreflightGate (Hermes turn_preflight_gate)', () {
    AgentContext bigCtx() => AgentContext(
          messages: [
            for (var i = 0; i < 6; i++)
              ChatMessage(role: 'user', content: 'x' * 200),
          ],
          tools: const [],
          session: Session(id: 's', channel: 'cli', userKey: 'u'),
        );

    test('di bawah ambang → ctx utuh, blocked false', () async {
      final gate = PreflightGate();
      final compact = Compactor(maxSoftTokens: 100000);
      final verdict = await gate.run(bigCtx(), compactor: compact);
      expect(verdict.blocked, isFalse);
      expect(verdict.pressure, isNotNull);
      expect(verdict.ctx.messages.length, 6);
      expect(gate.blockedInsufficientProgress, isFalse);
    });

    test('di atas ambang → kompresi preflight jalan + event trigger', () async {
      final events = <Map<String, dynamic>>[];
      final compact = Compactor(
        maxSoftTokens: 100,
        keepLastN: 2,
        onCompactionEvent: (e) => events.add(e.toJson()),
      );
      final gate = PreflightGate();
      final verdict = await gate.run(bigCtx(), compactor: compact);
      expect(compact.lastCompaction, isNotNull);
      expect(verdict.ctx.messages.length, lessThan(6));
      final preflightEvents =
          events.where((e) => e['trigger'] == 'preflight').toList();
      expect(preflightEvents, isNotEmpty);
      expect(preflightEvents.first['outcome'], 'committed');
    });

    test('progres tidak cukup → pass kedua diblokir', () async {
      final compact = Compactor(maxSoftTokens: 100, keepLastN: 2);
      final gate = PreflightGate(progressMinTokens: 100000);
      final first = await gate.run(bigCtx(), compactor: compact);
      expect(first.blocked, isFalse);
      final second = await gate.run(bigCtx(), compactor: compact);
      expect(second.blocked, isTrue);
      expect(gate.blockedInsufficientProgress, isTrue);
    });

    test('gerbang off → no-op', () async {
      final gate = PreflightGate(enabled: false);
      final verdict = await gate.run(bigCtx(), compactor: Compactor());
      expect(verdict.pressure, isNull);
      expect(verdict.blocked, isFalse);
    });
  });

  group('Router cooldown eksplisit (Hermes cooldown)', () {
    LlmProvider provider(String id) => _EchoLlm(id);

    test('setCooldown/isCoolingDown/cooldownRemainingSec', () {
      final router = Router(providers: {'a': provider('a')});
      expect(router.isCoolingDown('a'), isFalse);
      router.setCooldown('a', const Duration(seconds: 30));
      expect(router.isCoolingDown('a'), isTrue);
      expect(router.cooldownRemainingSec('a'), greaterThan(0));
      expect(router.cooldownSnapshot()['a'], isNotNull);
      router.setCooldown('a', Duration.zero);
      expect(router.isCoolingDown('a'), isFalse);
    });

    test('nextFallback melewatikan provider cooling (pass 1), fail-open pass 2',
        () {
      final a = provider('a');
      final b = provider('b');
      final router = Router(
        providers: {'a': a, 'b': b},
        defaultProviderId: 'a',
      );
      final decision = RouteDecision(
        llm: a,
        providerId: 'a',
        fallbackIds: const ['b'],
      );
      router.setCooldown('b', const Duration(minutes: 5));
      final next = router.nextFallback(decision, 'a');
      expect(next?.id, 'b',
          reason: 'pass 2 fail-open: b satu-satunya kandidat meski cooling');
      expect(router.fallbackEvents().first['to'], 'b');
    });

    test('nextFallback memilih kandidat non-cooling lebih dulu', () {
      final a = provider('a');
      final b = provider('b');
      final c = provider('c');
      final router = Router(
        providers: {'a': a, 'b': b, 'c': c},
        defaultProviderId: 'a',
      );
      final decision = RouteDecision(
        llm: a,
        providerId: 'a',
        fallbackIds: const ['b', 'c'],
      );
      router.setCooldown('b', const Duration(minutes: 5));
      final next = router.nextFallback(decision, 'a');
      expect(next?.id, 'c');
    });
  });

  group('Retry-After parser (Hermes provider_retry_after_seconds)', () {
    test('detik, format header/body umum', () {
      expect(
        ApiErrorClassifier.retryAfterSecondsFrom(
          message: 'HTTP 429: Too Many Requests. Please retry after 3600 seconds.',
        ),
        3600,
      );
      expect(
        ApiErrorClassifier.retryAfterSecondsFrom(
          message: 'rate limited; try again in 30s',
        ),
        30,
      );
      expect(
        ApiErrorClassifier.retryAfterSecondsFrom(
          code: '429',
          message: 'too many requests',
        ),
        isNull,
      );
      expect(ApiErrorClassifier.retryAfterSecondsFrom(message: ''), isNull);
    });
  });

  group('AgentLoop fase-8 wiring', () {
    test('stream macet tanpa progres → liveness abort, tanpa fallback',
        () async {
      final replies = <String>[];
      final hang = _HangingStreamLlm();
      final router = Router(
        providers: {'hang': hang},
        defaultProviderId: 'hang',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
        config: const AgentConfig(turnLivenessTimeoutSec: 1),
      );
      await loop.handle(
        const InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(loop.lastTurnEndReason, 'liveness_abort');
      expect(replies, isNotEmpty);
      expect(replies.last, contains('progres'));
      expect(replies.last, isNot(contains('fallback')));
      hang.dispose();
    });

    test('rate limit Retry-After > cap → cooldown_ends_turn + router cooldown',
        () async {
      final replies = <String>[];
      final router = Router(
        providers: {'limited': _RateLimitedLlm()},
        defaultProviderId: 'limited',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
        config: const AgentConfig(retryWaitCapSec: 90),
      );
      await loop.handle(
        const InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(loop.lastTurnEndReason, 'cooldown_ends_turn');
      expect(router.isCoolingDown('limited'), isTrue);
      expect(replies.last, contains('3600'));
    });

    test('orphan tool result dibuang sebelum request dikirim', () async {
      final replies = <String>[];
      final provider = _RecordingLlm();
      final router = Router(
        providers: {'rec': provider},
        defaultProviderId: 'rec',
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
      final session = Session(id: 's', channel: 'cli', userKey: 'u1');
      await loop.handle(
        const InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        session,
      );
      expect(provider.requests, isNotEmpty);
      for (final req in provider.requests) {
        expect(
          req.messages.any(
            (m) => m.role == 'tool' && m.toolCallId == 'ghost-call',
          ),
          isFalse,
        );
      }
    });

    test('preflight gate memicu kompresi trigger preflight saat di atas ambang',
        () async {
      final replies = <String>[];
      final compactionEvents = <Map<String, dynamic>>[];
      final router = Router(
        providers: {'mock': _EchoLlm('mock')},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(
          maxSoftTokens: 10,
          onCompactionEvent: (e) => compactionEvents.add(e.toJson()),
        ),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async => replies.add(text),
      );
      await loop.handle(
        InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'b' * 3000,
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(
        compactionEvents.any((e) => e['trigger'] == 'preflight'),
        isTrue,
      );
    });

    test('iteration budget observability terisi setelah turn', () async {
      final router = Router(
        providers: {'mock': _EchoLlm('mock')},
        defaultProviderId: 'mock',
      );
      final loop = AgentLoop(
        router: router,
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async {},
        config: const AgentConfig(
          maxIterations: 5,
          iterationWarnRatio: 0.8,
        ),
      );
      await loop.handle(
        const InboundMessage(
          channel: 'cli', userKey: 'u1', sessionKey: 'cli:u1', text: 'halo',
        ),
        Session(id: 's', channel: 'cli', userKey: 'u1'),
      );
      expect(loop.iterationsUsed, 1);
      expect(loop.iterationsRemaining, 4);
      expect(loop.iterationNearLimit, isTrue,
          reason: 'sisa 4 <= floor(5*0.8)=4');
    });
  });
}

class _EchoLlm implements LlmProvider {
  _EchoLlm(this.id);

  @override
  final String id;

  final String text = 'mock';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield LlmTextDelta(text);
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

/// Provider yang stream-nya "macet": satu event lalu tidak pernah ada
/// event/close lagi (StreamController tidak ditutup — cancel subscription
/// tetap segera, jadi abort liveness tidak menggantung test).
class _HangingStreamLlm implements LlmProvider {
  final controllers = <StreamController<LlmEvent>>[];

  void dispose() {
    for (final c in controllers) {
      if (!c.isClosed) c.close();
    }
  }

  @override
  String get id => 'hang';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) {
    final ctrl = StreamController<LlmEvent>();
    controllers.add(ctrl);
    ctrl.add(const LlmTextDelta('mulai'));
    return ctrl.stream;
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _RateLimitedLlm implements LlmProvider {
  @override
  String get id => 'limited';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    yield const LlmError(
      'HTTP 429: Too Many Requests. Please retry after 3600 seconds.',
      code: '429',
    );
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

class _RecordingLlm implements LlmProvider {
  final requests = <ChatRequest>[];

  @override
  String get id => 'rec';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    requests.add(req);
    yield const LlmTextDelta('ok');
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}
