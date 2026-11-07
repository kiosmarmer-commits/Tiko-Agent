import 'package:agent_core/agent_core.dart';

/// Circuit breaker + fallback chain (ALG-09, TASK-02-04).
///
/// After [failureThreshold] consecutive failures, the breaker opens for
/// [openDuration], then half-opens on the next attempt.
class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 3,
    this.openDuration = const Duration(seconds: 60),
  });

  final int failureThreshold;
  final Duration openDuration;

  int _failures = 0;
  DateTime? _openedAt;
  bool _halfOpen = false;

  bool get isOpen {
    if (_openedAt == null) return false;
    if (DateTime.now().toUtc().difference(_openedAt!) >= openDuration) {
      _halfOpen = true;
      return false; // allow one trial
    }
    return true;
  }

  void recordSuccess() {
    _failures = 0;
    _openedAt = null;
    _halfOpen = false;
  }

  void recordFailure() {
    _failures++;
    if (_failures >= failureThreshold) {
      _openedAt = DateTime.now().toUtc();
      _halfOpen = false;
    }
  }

  String get state {
    if (_openedAt != null && !_halfOpen && isOpen) return 'open';
    if (_halfOpen) return 'half_open';
    return 'closed';
  }
}

/// Wraps an [LlmProvider] with a circuit breaker.
class BreakerLlmProvider implements LlmProvider {
  BreakerLlmProvider(this.inner, {CircuitBreaker? breaker})
    : breaker = breaker ?? CircuitBreaker();

  final LlmProvider inner;
  final CircuitBreaker breaker;

  @override
  String get id => inner.id;

  @override
  Capabilities get capabilities => inner.capabilities;

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (breaker.isOpen) {
      yield LlmError(
        'circuit breaker open for ${inner.id}',
        code: 'breaker_open',
      );
      return;
    }
    try {
      var hadError = false;
      await for (final e in inner.chat(req)) {
        if (e is LlmError) hadError = true;
        yield e;
      }
      if (hadError) {
        breaker.recordFailure();
      } else {
        breaker.recordSuccess();
      }
    } catch (e) {
      breaker.recordFailure();
      yield LlmError(e.toString());
    }
  }

  @override
  Future<List<double>> embed(String text) => inner.embed(text);
}

/// Tries providers in order until one succeeds (fallback chain).
class FallbackLlmProvider implements LlmProvider {
  FallbackLlmProvider(this.providers, {this.id = 'fallback'});

  final List<LlmProvider> providers;

  @override
  final String id;

  @override
  Capabilities get capabilities => providers.isNotEmpty
      ? providers.first.capabilities
      : const Capabilities();

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    Object? lastError;
    for (final p in providers) {
      final events = <LlmEvent>[];
      var failed = false;
      try {
        await for (final e in p.chat(req)) {
          if (e is LlmError) {
            failed = true;
            lastError = e.message;
            break;
          }
          events.add(e);
        }
      } catch (e) {
        failed = true;
        lastError = e;
        continue;
      }
      if (!failed) {
        for (final e in events) {
          yield e;
        }
        return;
      }
    }
    yield LlmError(
      'semua provider gagal: $lastError',
      code: 'fallback_exhausted',
    );
  }

  @override
  Future<List<double>> embed(String text) async {
    for (final p in providers) {
      final v = await p.embed(text);
      if (v.isNotEmpty) return v;
    }
    return const [];
  }
}
