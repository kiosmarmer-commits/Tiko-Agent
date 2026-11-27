// Hermes fase-11 fast mode (`agent/fast_mode.py`): tabel kata service
// tier, jendela bounded (auto/cold), model tanpa kapasitas fast, dan
// wiring `service_tier` ke request provider.
import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  group('Tabel kata service tier (Hermes SERVICE_TIER_WORDS)', () {
    test('kata user/config → tier kanonik', () {
      expect(parseServiceTier('fast'), fastTierPriority);
      expect(parseServiceTier('priority'), fastTierPriority);
      expect(parseServiceTier('on'), fastTierPriority);
      expect(parseServiceTier('ultrafast'), fastTierUltrafast);
      expect(parseServiceTier('ultra'), fastTierUltrafast);
      expect(parseServiceTier('auto'), fastTierAuto);
      expect(parseServiceTier('cold'), fastTierCold);
    });

    test('kata normal dan tak dikenal → null (fail-open)', () {
      for (final w in ['', 'normal', 'default', 'standard', 'off', 'none']) {
        expect(parseServiceTier(w), isNull, reason: 'word: $w');
      }
      expect(parseServiceTier('ngebut'), isNull);
      expect(parseServiceTier(null), isNull);
      expect(parseServiceTier(' FAST '), fastTierPriority,
          reason: 'trim + case-insensitive');
    });

    test('parseExactServiceTier: eksplisit — unknown melempar', () {
      expect(parseExactServiceTier(''), isNull);
      expect(parseExactServiceTier('off'), isNull);
      expect(parseExactServiceTier('fast'), fastTierPriority);
      expect(() => parseExactServiceTier('ngebut'), throwsArgumentError);
    });

    test('serviceTierWord: priority → fast, null → normal', () {
      expect(serviceTierWord(fastTierPriority), 'fast');
      expect(serviceTierWord(fastTierUltrafast), 'ultrafast');
      expect(serviceTierWord(fastTierAuto), 'auto');
      expect(serviceTierWord(null), 'normal');
      expect(serviceTierWord(''), 'normal');
    });
  });

  group('FastModeState (jendela bounded)', () {
    test('auto: jendela terbuka per turn lalu kedaluwarsa (clock injeksi)',
        () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final fm = FastModeState(clock: () => now)..tier = fastTierAuto;
      fm.window = const Duration(seconds: 60);
      fm.beginTurn(const []);
      expect(fm.windowOpen(), isTrue);
      expect(fm.effectiveServiceTier('gpt-x'), fastTierAuto);
      now = now.add(const Duration(seconds: 61));
      expect(fm.windowOpen(), isFalse);
      expect(fm.effectiveServiceTier('gpt-x'), isNull);
    });

    test('cold: hanya turn pertama tanpa riwayat user/assistant/tool', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final fm = FastModeState(clock: () => now)..tier = fastTierCold;
      fm.beginTurn(const []);
      expect(fm.windowOpen(), isTrue, reason: 'turn pertama → jendela buka');
      now = now.add(const Duration(seconds: 120));
      // Turn kedua: riwayat sudah berisi percakapan → jendela ditolak.
      fm.beginTurn(const [
        ChatMessage(role: 'user', content: 'halo'),
        ChatMessage(role: 'assistant', content: 'hai'),
      ]);
      expect(fm.windowOpen(), isFalse);
      // Riwayat berisi system saja tetap dianggap turn pertama.
      fm.beginTurn(const [ChatMessage(role: 'system', content: 'sys')]);
      expect(fm.windowOpen(), isTrue);
    });

    test('static tier: selalu efektif tanpa jendela', () {
      final fm = FastModeState()..tier = fastTierPriority;
      fm.beginTurn(const []);
      expect(fm.windowOpen(), isFalse, reason: 'static tier tidak buka jendela');
      expect(fm.effectiveServiceTier('gpt-x'), fastTierPriority);
      // normal: tidak pernah mengirim tier.
      final fmNormal = FastModeState()..tier = null;
      expect(fmNormal.effectiveServiceTier('gpt-x'), isNull);
    });

    test('markUnavailable: sekali saja; model tertandai tak menerima tier',
        () {
      final fm = FastModeState()..tier = fastTierPriority;
      expect(fm.markUnavailable('gpt-x'), isTrue);
      expect(fm.markUnavailable('gpt-x'), isFalse);
      expect(fm.markUnavailable(null), isFalse);
      expect(fm.effectiveServiceTier('gpt-x'), isNull);
      expect(fm.effectiveServiceTier('gpt-y'), fastTierPriority);
      // Model tanpa kapasitas fast tidak di-reset oleh beginTurn.
      fm.beginTurn(const []);
      expect(fm.effectiveServiceTier('gpt-x'), isNull);
    });

    test('fastModeUnprovisioned: 429 + header limit fast = 0', () {
      expect(
        fastModeUnprovisioned(
          statusCode: 429,
          headers: {'anthropic-fast-input-tokens-limit': '0'},
        ),
        isTrue,
      );
      expect(
        fastModeUnprovisioned(
          statusCode: 429,
          headers: {'anthropic-fast-output-tokens-limit': ' 0 '},
        ),
        isTrue,
      );
      expect(
        fastModeUnprovisioned(
          statusCode: 429,
          headers: {'anthropic-fast-input-tokens-limit': '1000'},
        ),
        isFalse,
      );
      expect(
        fastModeUnprovisioned(statusCode: 500, headers: const {}),
        isFalse,
      );
      expect(
        fastModeUnprovisioned(statusCode: 429, headers: const {}),
        isFalse,
      );
    });
  });

  group('AgentLoop fast-mode wiring', () {
    test('tier static terlampir ke request provider; normal tidak', () async {
      final sent = <ChatRequest>[];
      final loop = AgentLoop(
        router: Router(
          providers: {'e': _CapturingLlm(sent)},
          defaultProviderId: 'e',
        ),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async {},
        fastMode: (FastModeState()..tier = fastTierPriority),
      );
      final session = Session(id: 's11', channel: 'cli', userKey: 'u1');
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'halo',
        ),
        session,
      );
      expect(sent, isNotEmpty);
      expect(sent.every((r) => r.serviceTier == fastTierPriority), isTrue);

      final sent2 = <ChatRequest>[];
      final loopNormal = AgentLoop(
        router: Router(
          providers: {'e': _CapturingLlm(sent2)},
          defaultProviderId: 'e',
        ),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async {},
        fastMode: FastModeState(),
      );
      await loopNormal.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'halo',
        ),
        Session(id: 's11b', channel: 'cli', userKey: 'u1'),
      );
      expect(sent2.every((r) => r.serviceTier == null), isTrue);
    });

    test('auto: jendela terbuka di turn user; kedaluwarsa → tanpa tier',
        () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final sent = <ChatRequest>[];
      final fm = FastModeState(clock: () => now)..tier = fastTierAuto;
      final loop = AgentLoop(
        router: Router(
          providers: {'e': _CapturingLlm(sent)},
          defaultProviderId: 'e',
        ),
        contextBuilder: ContextBuilder(),
        compactor: Compactor(),
        gate: AllowAllGate(),
        executor: MockToolExecutor(),
        memory: NoopMemory(),
        reply: (m, text) async {},
        fastMode: fm,
      );
      final session = Session(id: 's11c', channel: 'cli', userKey: 'u1');
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'halo',
        ),
        session,
      );
      expect(sent.every((r) => r.serviceTier == fastTierAuto), isTrue);

      now = now.add(const Duration(seconds: 120));
      await loop.handle(
        const InboundMessage(
          channel: 'cli',
          userKey: 'u1',
          sessionKey: 'cli:u1',
          text: 'lanjut',
        ),
        session,
      );
      expect(
        sent.last.serviceTier,
        fastTierAuto,
        reason: 'mode auto membuka jendela BARU di setiap user turn '
            '(Hermes beginTurn); jendela di antara turn tertutup',
      );
      // Di luar jendela (tanpa turn baru) — tidak ada tier.
      now = now.add(const Duration(seconds: 120));
      expect(fm.windowOpen(), isFalse);
      expect(fm.effectiveServiceTier('e'), isNull);
    });
  });
}

/// Provider echo yang merekam request yang dikirim (tier wire).
class _CapturingLlm implements LlmProvider {
  _CapturingLlm(this.sent);

  final List<ChatRequest> sent;

  @override
  String get id => 'e';

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    sent.add(req);
    yield const LlmTextDelta('mock');
    yield const LlmDone(finishReason: 'stop');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}
