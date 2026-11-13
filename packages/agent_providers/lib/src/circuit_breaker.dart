import 'package:agent_core/agent_core.dart';

/// Fase circuit breaker (ALG-09, TASK-02-04). Half-open adalah jendela
/// percobaan tunggal setelah [CircuitBreaker.openDuration] berlalu.
enum BreakerPhase { closed, open, halfOpen }

/// Circuit breaker + fallback chain (ALG-09, TASK-02-04).
///
/// Unified state machine: [CircuitBreaker] adalah adapter tipis di atas
/// [ProviderHealth] (agent_core) — implementasi fase closed/open/half-open
/// hanya ada SATU. Bila [health] disuntik, breaker berbagi state dengan
/// pemilik instance tersebut (mis. `Router.health`), sehingga kegagalan
/// yang dicatat pemakaian langsung provider langsung terlihat oleh Router,
/// dan sebaliknya. Tanpa injeksi, breaker membuat [ProviderHealth] sendiri.
///
/// Setelah [failureThreshold] kegagalan beruntun, breaker membuka selama
/// [openDuration], lalu masuk half-open: tepat SATU percobaan probe yang
/// boleh lewat ([tryAcquire]); pemanggil lain ditolak seolah breaker masih
/// terbuka. Probe sukses menutup breaker, probe gagal membuka ulang
/// jendela penuh. Waktu dibaca dari [clock] agar perilaku dapat diuji
/// deterministik.
class CircuitBreaker {
  CircuitBreaker({
    int failureThreshold = 3,
    Duration openDuration = const Duration(seconds: 60),
    DateTime Function()? clock,
    ProviderHealth? health,
  }) : health = health ??
            ProviderHealth(
              failureThreshold: failureThreshold,
              openDuration: openDuration,
              clock: clock,
            );

  /// State machine bersama yang menyimpan fase, failure/success count,
  /// latensi terakhir, dan slot probe half-open.
  final ProviderHealth health;

  /// Fase saat ini, murni pembacaan tanpa efek samping.
  BreakerPhase get phase => switch (health.state) {
        'open' => BreakerPhase.open,
        'half_open' => BreakerPhase.halfOpen,
        _ => BreakerPhase.closed,
      };

  /// Kompatibilitas pemanggil lama: true berarti panggilan DITOLAK
  /// (breaker terbuka penuh). Pada fase half-open pemanggil tidak langsung
  /// ditolak, tetapi wajib memenangkan slot probe lewat [tryAcquire].
  bool get isOpen => phase == BreakerPhase.open;

  /// Status sebagai string ('closed' | 'open' | 'half_open').
  String get state => health.state;

  /// True bila panggilan ini boleh mengeksekusi provider yang dijaga.
  /// - closed: selalu diizinkan.
  /// - open: selalu ditolak.
  /// - half-open: hanya pemanggil PERTAMA yang mendapat slot probe;
  ///   pemanggil lain ditolak sampai ada verdict ([recordSuccess] /
  ///   [recordFailure]) atau slot dilepas dengan [releaseProbe].
  bool tryAcquire() => health.tryAcquire();

  void recordSuccess({double latencyMs = 0}) =>
      health.recordSuccess(latencyMs);

  void recordFailure([String error = 'provider error']) =>
      health.recordFailure(error);

  /// Melepas slot probe tanpa verdict (misalnya stream dibatalkan pemanggil)
  /// supaya fase half-open tidak menahan satu-satunya slot selamanya.
  void releaseProbe() => health.releaseProbe();
}

/// Wraps an [LlmProvider] with a circuit breaker.
///
/// Bila [health] disuntik, breaker BERBAGI state [ProviderHealth] dengan
/// pemanggil lain (mis. Router) — satu kegagalan tercatat sekali dan
/// terlihat di semua permukaan. Tanpa injeksi, breaker berdiri sendiri.
class BreakerLlmProvider implements LlmProvider {
  BreakerLlmProvider(this.inner, {CircuitBreaker? breaker, ProviderHealth? health})
    : breaker = breaker ??
          (health == null ? CircuitBreaker() : CircuitBreaker(health: health));

  final LlmProvider inner;
  final CircuitBreaker breaker;

  @override
  String get id => inner.id;

  @override
  Capabilities get capabilities => inner.capabilities;

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    if (!breaker.tryAcquire()) {
      yield LlmError(
        'circuit breaker open for ${inner.id}',
        code: 'breaker_open',
      );
      return;
    }
    var hadError = false;
    var completed = false;
    var lastError = '';
    final sw = Stopwatch()..start();
    try {
      await for (final e in inner.chat(req)) {
        if (e is LlmError) {
          hadError = true;
          lastError = e.message;
        }
        yield e;
      }
      completed = true;
    } catch (e) {
      hadError = true;
      lastError = e.toString();
      yield LlmError(e.toString());
    } finally {
      sw.stop();
      if (hadError) {
        breaker.recordFailure(lastError);
      } else if (completed) {
        breaker.recordSuccess(latencyMs: sw.elapsedMilliseconds.toDouble());
      } else {
        // Stream dibatalkan sebelum ada verdict: lepas slot probe tanpa
        // mengubah state supaya half-open tidak macet.
        breaker.releaseProbe();
      }
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
    var breakerBlocked = 0;
    for (final p in providers) {
      final events = <LlmEvent>[];
      var failed = false;
      try {
        await for (final e in p.chat(req)) {
          if (e is LlmError) {
            failed = true;
            lastError = e.message;
            if (e.code == 'breaker_open') breakerBlocked++;
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
    // Deterministik saat SEMUA provider unhealthy: tidak ada satu pun
    // request yang benar-benar dieksekusi, jadi jangan laporkan sebagai
    // kegagalan eksekusi generik — kondisinya disebut eksplisit supaya
    // caller bisa membedakan "coba lagi nanti" dari "provider error".
    if (providers.isNotEmpty && breakerBlocked == providers.length) {
      yield LlmError(
        'semua provider unhealthy (circuit breaker terbuka): $lastError',
        code: 'all_breakers_open',
      );
      return;
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
