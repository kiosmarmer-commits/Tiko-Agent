import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// Provider yang memutar skrip respons: tiap panggilan chat() mengambil
/// item berikutnya. Item berupa error (code, message) atau teks jawaban
/// (code null).
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.id, this.scripts);
  @override
  final String id;
  final List<(String? code, String message)> scripts;
  int calls = 0;

  @override
  Capabilities get capabilities => const Capabilities(toolCalling: false);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    final i = calls < scripts.length ? calls : scripts.length - 1;
    calls++;
    if (scripts[i].$1 != null) {
      yield LlmError(scripts[i].$2, code: scripts[i].$1);
    } else {
      yield LlmTextDelta(scripts[i].$2);
      yield const LlmDone();
    }
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

void main() {
  group('ApiErrorClassifier — tabel klasifikasi', () {
    ApiError cls(String? code, [String message = '']) =>
        ApiErrorClassifier.classify(code: code, message: message);

    test('401 dan 403 → auth', () {
      expect(cls('401').kind, ApiErrorKind.auth);
      expect(cls('403', 'Forbidden').kind, ApiErrorKind.auth);
    });

    test('429 → rateLimit dan bisa di-retry provider yang sama', () {
      final e = cls('429', 'HTTP 429: rate limit exceeded');
      expect(e.kind, ApiErrorKind.rateLimit);
      expect(e.retrySameProvider, isTrue);
      expect(e.terminal, isFalse);
    });

    test('413 → overflow', () {
      expect(cls('413').kind, ApiErrorKind.overflow);
    });

    test('body context overflow tanpa status → overflow', () {
      final e = cls(null,
          "HTTP 400: This model's maximum context length is 8192 tokens");
      expect(e.kind, ApiErrorKind.overflow);
      expect(e.retrySameProvider, isTrue);
    });

    test('402 → billing terminal', () {
      final e = cls('402', 'HTTP 402: Payment Required');
      expect(e.kind, ApiErrorKind.billing);
      expect(e.terminal, isTrue);
      expect(e.retrySameProvider, isFalse);
    });

    test('body billing tanpa status → billing terminal', () {
      final e = cls(null, 'insufficient funds: your credit balance is too low');
      expect(e.kind, ApiErrorKind.billing);
      expect(e.terminal, isTrue);
    });

    test('5xx → server', () {
      expect(cls('500').kind, ApiErrorKind.server);
      expect(
          cls('503', 'HTTP 503: Service Unavailable').kind, ApiErrorKind.server);
      expect(cls('500').retrySameProvider, isFalse);
    });

    test('pola jaringan → network', () {
      expect(cls(null, 'Connection refused').kind, ApiErrorKind.network);
      expect(cls(null, 'request timeout after 30s').kind, ApiErrorKind.network);
      expect(cls(null, 'Failed host lookup: api.example.com').kind,
          ApiErrorKind.network);
    });

    test('status dari body HTTP prefix saat code kosong', () {
      final e = cls(null, 'HTTP 429: too many requests');
      expect(e.statusCode, 429);
      expect(e.kind, ApiErrorKind.rateLimit);
    });

    test('unknown untuk pesan tak dikenal', () {
      expect(cls(null, 'sesuatu aneh').kind, ApiErrorKind.unknown);
    });
  });

  group('Recovery chain di AgentLoop', () {
    late Session session;
    late List<String> replies;

    setUp(() {
      replies = [];
      session = Session(id: 'test-session', channel: 'cli', userKey: 'user1');
    });

    Future<(AgentLoop, Router)> buildLoop(
        List<_ScriptedProvider> providers) async {
      final router = Router(
        providers: {
          for (final p in providers) p.id: p,
        },
        defaultProviderId: providers.first.id,
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
      return (loop, router);
    }

    Future<void> run(AgentLoop loop, String text) => loop.handle(
          InboundMessage(
            channel: 'cli',
            userKey: 'user1',
            sessionKey: 'cli:user1',
            text: text,
          ),
          session,
        );

    test('billing (402) → terminal, tidak lanjut fallback', () async {
      final primary = _ScriptedProvider('primary', [
        ('402', 'HTTP 402: Payment Required'),
      ]);
      final fallback = _ScriptedProvider('fallback', [
        (null, 'jawaban fallback'),
      ]);
      final (loop, _) = await buildLoop([primary, fallback]);
      await run(loop, 'halo');

      expect(primary.calls, 1);
      expect(fallback.calls, 0);
      expect(replies.join('\n'), contains('billing'));
      expect(loop.lastTurnEndReason, 'billing_error');
      expect(loop.lastTurnEndExplanation, isNotEmpty);
    });

    test('rate limit (429) → backoff lalu retry provider yang sama', () async {
      final primary = _ScriptedProvider('primary', [
        ('429', 'HTTP 429: rate limit exceeded'),
        (null, 'jawaban pulih'),
      ]);
      final (loop, router) = await buildLoop([primary]);
      await run(loop, 'halo');

      expect(primary.calls, 2);
      expect(replies.last, contains('jawaban pulih'));
      expect(loop.lastTurnEndReason, 'completed');
      expect(
        router.health['primary']!.failures,
        0,
        reason: 'recovery berhasil tidak boleh dicatat sebagai kegagalan',
      );
    });

    test('overflow (413) → retry provider yang sama setelah kompresi', () async {
      final primary = _ScriptedProvider('primary', [
        ('413', 'HTTP 413: context_length_exceeded'),
        (null, 'jawaban pulih'),
      ]);
      final (loop, router) = await buildLoop([primary]);
      await run(loop, 'halo');

      expect(primary.calls, 2);
      expect(replies.last, contains('jawaban pulih'));
      expect(loop.lastTurnEndReason, 'completed');
      expect(router.health['primary']!.failures, 0);
    });

    test('server 5xx → tidak di-retry provider sama, langsung fallback',
        () async {
      final primary = _ScriptedProvider('primary', [
        ('500', 'HTTP 500: internal server error'),
      ]);
      final fallback = _ScriptedProvider('fallback', [
        (null, 'jawaban fallback'),
      ]);
      final (loop, _) = await buildLoop([primary, fallback]);
      await run(loop, 'halo');

      expect(primary.calls, 1);
      expect(fallback.calls, 1);
      expect(replies.last, contains('jawaban fallback'));
      expect(loop.lastTurnEndReason, 'completed');
    });
  });
}
