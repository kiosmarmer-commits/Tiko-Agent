import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

ChatRequest get _req => const ChatRequest(
      messages: [ChatMessage(role: 'user', content: 'halo')],
    );

Future<List<LlmEvent>> _collect(Stream<LlmEvent> events) => events.toList();

/// Provider yang selalu gagal; menghitung berapa kali benar-benar dieksekusi.
class _FailingProvider implements LlmProvider {
  _FailingProvider(this.pid);

  final String pid;
  int attempts = 0;

  @override
  String get id => pid;

  @override
  Capabilities get capabilities => const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    attempts++;
    yield const LlmError('provider down', code: 'provider_error');
  }

  @override
  Future<List<double>> embed(String text) async => const [];
}

void main() {
  test('breaker tertutup mengizinkan semua panggilan', () {
    final b = CircuitBreaker();
    expect(b.state, 'closed');
    expect(b.tryAcquire(), isTrue);
    expect(b.tryAcquire(), isTrue);
  });

  test('threshold kegagalan membuka breaker dan menolak panggilan', () {
    var now = DateTime.utc(2026, 11, 9, 12);
    final b = CircuitBreaker(
      failureThreshold: 3,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    b.recordFailure();
    b.recordFailure();
    expect(b.state, 'closed');
    b.recordFailure();
    expect(b.state, 'open');
    expect(b.tryAcquire(), isFalse);
  });

  test('half-open memberi tepat satu slot probe', () {
    var now = DateTime.utc(2026, 11, 9, 12);
    final b = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    b.recordFailure();
    expect(b.state, 'open');
    now = now.add(const Duration(seconds: 61));
    expect(b.state, 'half_open');
    expect(b.tryAcquire(), isTrue);
    expect(b.tryAcquire(), isFalse, reason: 'probe kedua harus ditolak');
    // Probe gagal -> membuka ulang jendela penuh.
    b.recordFailure();
    expect(b.state, 'open');
    now = now.add(const Duration(seconds: 61));
    expect(b.tryAcquire(), isTrue);
    // Probe sukses -> menutup breaker sepenuhnya.
    b.recordSuccess();
    expect(b.state, 'closed');
  });

  test('releaseProbe membebaskan slot tanpa verdict', () {
    var now = DateTime.utc(2026, 11, 9, 12);
    final b = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    b.recordFailure();
    now = now.add(const Duration(seconds: 61));
    expect(b.tryAcquire(), isTrue);
    expect(b.tryAcquire(), isFalse);
    b.releaseProbe();
    expect(b.tryAcquire(), isTrue);
  });

  test('BreakerLlmProvider menolak cepat saat breaker terbuka', () async {
    var now = DateTime.utc(2026, 11, 9, 12);
    final inner = _FailingProvider('p1');
    final b = CircuitBreaker(
      failureThreshold: 2,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    final wrapped = BreakerLlmProvider(inner, breaker: b);
    await _collect(wrapped.chat(_req));
    await _collect(wrapped.chat(_req));
    expect(inner.attempts, 2);
    expect(b.state, 'open');
    final blocked = await _collect(wrapped.chat(_req));
    expect(inner.attempts, 2, reason: 'tidak boleh menyentuh provider');
    expect(blocked, hasLength(1));
    expect((blocked.single as LlmError).code, 'breaker_open');
  });

  test('probe half-open dieksekusi sekali lalu membuka ulang breaker',
      () async {
    var now = DateTime.utc(2026, 11, 9, 12);
    final inner = _FailingProvider('p1');
    final b = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    final wrapped = BreakerLlmProvider(inner, breaker: b);
    await _collect(wrapped.chat(_req));
    expect(b.state, 'open');
    now = now.add(const Duration(seconds: 61));
    await _collect(wrapped.chat(_req));
    expect(inner.attempts, 2, reason: 'probe tunggal harus mengeksekusi');
    expect(b.state, 'open', reason: 'probe gagal membuka ulang breaker');
  });

  test('FallbackLlmProvider sukses saat ada provider sehat', () async {
    final fallback = FallbackLlmProvider([
      _FailingProvider('buruk'),
      MockLlmProvider(),
    ]);
    final events = await _collect(fallback.chat(_req));
    expect(events.whereType<LlmError>(), isEmpty);
    expect(events.whereType<LlmTextDelta>(), isNotEmpty);
  });

  test('semua breaker terbuka -> error deterministik all_breakers_open',
      () async {
    var now = DateTime.utc(2026, 11, 9, 12);
    final b1 = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    final b2 = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    final fallback = FallbackLlmProvider([
      BreakerLlmProvider(_FailingProvider('p1'), breaker: b1),
      BreakerLlmProvider(_FailingProvider('p2'), breaker: b2),
    ]);
    // Percakapan pertama: kedua provider benar-benar dieksekusi dan gagal.
    final first = await _collect(fallback.chat(_req));
    expect((first.whereType<LlmError>().single as LlmError).code,
        'fallback_exhausted');
    // Percakapan kedua: kedua breaker terbuka -> deterministik.
    final second = await _collect(fallback.chat(_req));
    final err = second.whereType<LlmError>().single as LlmError;
    expect(err.code, 'all_breakers_open');
  });

  test('breaker terbuka + kegagalan nyata tetap fallback_exhausted', () async {
    var now = DateTime.utc(2026, 11, 9, 12);
    final b1 = CircuitBreaker(
      failureThreshold: 1,
      openDuration: const Duration(seconds: 60),
      clock: () => now,
    );
    final fallback = FallbackLlmProvider([
      BreakerLlmProvider(_FailingProvider('p1'), breaker: b1),
      _FailingProvider('p2'),
    ]);
    await _collect(fallback.chat(_req));
    final second = await _collect(fallback.chat(_req));
    final err = second.whereType<LlmError>().single as LlmError;
    expect(err.code, 'fallback_exhausted');
  });
}
