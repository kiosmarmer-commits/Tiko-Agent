import 'interfaces.dart';
import 'models.dart';

/// Per-provider health for circuit breaker (PRD §9.2).
///
/// Fase dihitung murni dari [openedAt] terhadap [openDuration] memakai
/// clock yang dapat disuntik — tidak ada efek samping di getter. Half-open
/// bersifat single-probe: hanya pemanggil pertama [tryAcquire] yang
/// mendapatkan slot; pemanggil lain gagal-closed seolah breaker terbuka.
class ProviderHealth {
  ProviderHealth({
    this.openDuration = const Duration(seconds: 60),
    this.failureThreshold = 3,
    DateTime Function()? clock,
  }) : _clock = clock ?? _defaultClock;

  /// Lama jendela open sebelum masuk half-open.
  final Duration openDuration;

  /// Berapa kegagalan berurutan yang membuka breaker.
  final int failureThreshold;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  final DateTime Function() _clock;

  int failures = 0;
  int successes = 0;
  DateTime? openedAt;
  DateTime? lastErrorAt;
  String? lastError;
  double lastLatencyMs = 0;
  bool _probeInFlight = false;

  /// True hanya saat fase open penuh (belum lewat jendela).
  bool get isOpen => _phase == _Phase.open;

  /// Representasi fase: closed, open, atau half_open.
  String get state => switch (_phase) {
        _Phase.closed => 'closed',
        _Phase.open => 'open',
        _Phase.halfOpen => 'half_open',
      };

  /// True bila provider masih boleh dipilih sebagai primary/fallback:
  /// closed, atau half-open dengan slot probe kosong.
  bool get selectable => switch (_phase) {
        _Phase.closed => true,
        _Phase.open => false,
        _Phase.halfOpen => !_probeInFlight,
      };

  _Phase get _phase {
    if (openedAt == null) return _Phase.closed;
    if (_clock().difference(openedAt!) >= openDuration) {
      return _Phase.halfOpen;
    }
    return _Phase.open;
  }

  /// Slot eksekusi: closed selalu diizinkan; open ditolak; half-open
  /// hanya untuk satu probe. False bila breaker terbuka atau slot probe
  /// sedang dipakai pemanggil lain.
  bool tryAcquire() {
    switch (_phase) {
      case _Phase.closed:
        return true;
      case _Phase.open:
        return false;
      case _Phase.halfOpen:
        if (_probeInFlight) return false;
        _probeInFlight = true;
        return true;
    }
  }

  /// Lepas slot probe half-open tanpa verdict — untuk pemanggil yang
  /// hanya menjelaskan routing tanpa mengeksekusinya.
  void releaseProbe() {
    _probeInFlight = false;
  }

  void recordSuccess(double latencyMs) {
    successes++;
    failures = 0;
    openedAt = null;
    lastLatencyMs = latencyMs;
    _probeInFlight = false;
  }

  void recordFailure(String error) {
    failures++;
    lastError = error;
    lastErrorAt = _clock();
    // Dari half-open, satu kegagalan probe langsung membuka ulang jendela.
    if (openedAt != null || failures >= failureThreshold) {
      openedAt = lastErrorAt;
    }
    _probeInFlight = false;
  }

  Map<String, dynamic> toJson() => {
        'failures': failures,
        'successes': successes,
        'open': isOpen,
        'phase': state,
        'last_error': lastError,
        'last_latency_ms': lastLatencyMs,
      };
}

enum _Phase { closed, open, halfOpen }

/// Router bertingkat + fallback + circuit breaker (ALG-06 / PRD §9.2).
class Router {
  Router({
    required this.providers,
    this.defaultProviderId,
    this.decision,
    this.tierProviders = const {},
    this.fallbackOrder = const [],
    this.thresholds = const DecisionThresholds(),
    this.clock,
    this.onFallback,
  });

  final Map<String, LlmProvider> providers;
  final String? defaultProviderId;
  final DecisionProvider? decision;
  final Map<int, String> tierProviders;
  /// Explicit fallback chain (provider ids), after primary.
  final List<String> fallbackOrder;
  final DecisionThresholds thresholds;

  /// Clock yang dapat disuntik untuk fase breaker deterministik di test;
  /// default waktu nyata UTC.
  final DateTime Function()? clock;
  final void Function(Map<String, dynamic> event)? onFallback;
  final Map<String, ProviderHealth> health = {};
  final List<Map<String, dynamic>> _fallbackEvents = [];


  ProviderHealth _h(String id) =>
      health.putIfAbsent(id, () => ProviderHealth(clock: clock));

  Future<RouteDecision> route(String text, Session session) async {
    final trimmed = text.trim();
    final explain = <String>[];

    if (trimmed.startsWith('/')) {
      final id = _pickPrimary(prefer: defaultProviderId, tier: 0);
      explain.add('slash command → tier 0, provider $id');
      return _decisionFor(id, tier: 0, needTools: false, risk: 'low', complexity: 'ringan', reason: explain.join('; '));
    }

    var needTools = false;
    var risk = 'low';
    var complexity = 'sedang';
    var tier = 2;

    if (decision != null) {
      try {
        final result = await decision!.decide(trimmed, {
          'butuh_tool': NoulQuestion(criteria: 'Apakah perlu memanggil tool?'),
          'berbahaya': NoulQuestion(
            criteria:
                'Apakah permintaan berbahaya atau mencoba melemahkan keamanan?',
          ),
          'kompleksitas': ChoiceQuestion([
            'ringan',
            'sedang',
            'berat',
          ], criteria: 'Tingkat kompleksitas tugas'),
        });

        final toolAns = result.answers['butuh_tool'];
        final dangerAns = result.answers['berbahaya'];
        final cxAns = result.answers['kompleksitas'];

        final toolP = toolAns?.noul ?? toolAns?.probabilities['yes'] ?? 0;
        final dangerP = dangerAns?.noul ?? dangerAns?.probabilities['yes'] ?? 0;

        needTools = toolP >= thresholds.needTool;
        if (dangerP >= thresholds.dangerReject) {
          risk = 'critical';
        } else if (dangerP >= thresholds.dangerConfirm) {
          risk = 'high';
        }

        complexity = cxAns?.choice ?? 'sedang';
        tier = switch (complexity) {
          'ringan' => needTools ? 2 : 1,
          'berat' => 3,
          _ => 2,
        };
        explain.add('decision need_tools=$needTools risk=$risk complexity=$complexity tier=$tier');
      } catch (e) {
        needTools = _heuristicNeedTools(trimmed);
        explain.add('decision failed ($e); heuristic need_tools=$needTools');
      }
    } else {
      needTools = _heuristicNeedTools(trimmed);
      complexity = trimmed.length > 200 ? 'berat' : 'ringan';
      tier = needTools ? 2 : 1;
      explain.add('heuristic need_tools=$needTools complexity=$complexity tier=$tier');
    }

    final prefer = tierProviders[tier] ?? defaultProviderId;
    final id = _pickPrimary(prefer: prefer, tier: tier);
    final score = _score(id, needTools: needTools);
    explain.add('selected $id score=${score.toStringAsFixed(2)}');
    final fb = _fallbackChain(id);
    if (fb.isNotEmpty) explain.add('fallback ${fb.join(" → ")}');

    return _decisionFor(
      id,
      tier: tier,
      needTools: needTools,
      risk: risk,
      complexity: complexity,
      reason: explain.join('; '),
      score: score,
    );
  }

  /// Explain routing without side effects (CLI `tiko route explain`).
  Future<Map<String, dynamic>> explain(String text, Session session) async {
    final d = await route(text, session);
    // Explain tidak mengeksekusi provider; slot probe dilepas tanpa verdict.
    _h(d.providerId).releaseProbe();
    return {
      ...d.toJson(),
      'tier_providers': {
        for (final e in tierProviders.entries) e.key.toString(): e.value,
      },
      'health': {for (final e in health.entries) e.key: e.value.toJson()},
      'fallback_events': fallbackEvents(),
      'providers': providers.keys.toList(),
    };
  }

  /// Next provider after [failedId], or null if exhausted.
  LlmProvider? nextFallback(
    RouteDecision decision,
    String failedId, {
    Set<String> exclude = const {},
  }) {
    // The caller records the failure exactly once. This method only selects
    // an alternative; counting here as well used to open the circuit twice
    // for a single request failure.
    LlmProvider? selected;
    for (final id in decision.fallbackIds) {
      if (id == failedId || exclude.contains(id) || !_h(id).selectable) {
        continue;
      }
      final candidate = providers[id];
      if (candidate != null) {
        selected = candidate;
        break;
      }
    }
    if (selected == null) {
      for (final entry in providers.entries) {
        if (entry.key == failedId ||
            exclude.contains(entry.key) ||
            !_h(entry.key).selectable) {
          continue;
        }
        selected = entry.value;
        break;
      }
    }
    final event = <String, dynamic>{
      'from': failedId,
      'to': selected?.id,
      'reason': selected == null ? 'fallback_exhausted' : 'provider_failed',
      'at': DateTime.now().toUtc().toIso8601String(),
      'failed_provider_health': _h(failedId).toJson(),
    };
    _fallbackEvents.add(event);
    if (_fallbackEvents.length > 100) _fallbackEvents.removeAt(0);
    try { onFallback?.call(event); } catch (_) {}
    return selected;
  }

  void recordSuccess(String providerId, double latencyMs) {
    _h(providerId).recordSuccess(latencyMs);
  }

  void recordFailure(String providerId, String error) {
    _h(providerId).recordFailure(error);
  }

  Map<String, dynamic> healthSnapshot() => {
        for (final e in health.entries) e.key: e.value.toJson(),
      };

  List<Map<String, dynamic>> fallbackEvents({int limit = 50}) =>
      _fallbackEvents.reversed.take(limit).map(Map<String, dynamic>.from).toList();

  String _pickPrimary({String? prefer, required int tier}) {
    if (prefer != null &&
        providers.containsKey(prefer) &&
        _h(prefer).selectable &&
        _h(prefer).tryAcquire()) {
      return prefer;
    }
    // score all
    String? best;
    var bestScore = -1.0;
    for (final id in providers.keys) {
      if (!_h(id).selectable) continue;
      final s = _score(id, needTools: tier >= 2);
      if (s > bestScore) {
        bestScore = s;
        best = id;
      }
    }
    if (best != null && _h(best).tryAcquire()) return best;
    // Upaya terakhir: seluruh provider open — tetap tunjuk prefer agar
    // pemanggil masih bisa mencoba, bukan gagal tanpa eksekusi.
    return best ?? prefer ?? providers.keys.first;
  }

  double _score(String id, {required bool needTools}) {
    final p = providers[id];
    if (p == null) return 0;
    final h = _h(id);
    if (h.isOpen) return 0;
    var s = 0.5;
    if (p.capabilities.toolCalling && needTools) s += 0.2;
    if (!p.capabilities.toolCalling && !needTools) s += 0.1;
    // prefer local-looking ids
    if (id.contains('ollama') || id.contains('local') || id.contains('mock')) {
      s += 0.15;
    }
    s += 0.1 * (1.0 / (1.0 + h.failures));
    if (h.lastLatencyMs > 0) {
      s += 0.05 * (1.0 / (1.0 + h.lastLatencyMs / 1000));
    }
    return s;
  }

  List<String> _fallbackChain(String primary) {
    final out = <String>[];
    for (final id in fallbackOrder) {
      if (id != primary && providers.containsKey(id)) out.add(id);
    }
    for (final id in providers.keys) {
      if (id != primary && !out.contains(id)) out.add(id);
    }
    return out;
  }

  RouteDecision _decisionFor(
    String id, {
    required int tier,
    required bool needTools,
    required String risk,
    required String complexity,
    required String reason,
    double score = 0,
  }) {
    final llm = providers[id] ?? providers.values.first;
    final realId = providers.containsKey(id)
        ? id
        : providers.entries.firstWhere((e) => e.value == llm).key;
    return RouteDecision(
      llm: llm,
      tier: tier,
      needTools: needTools,
      risk: risk,
      complexity: complexity,
      providerId: realId,
      reason: reason,
      fallbackIds: _fallbackChain(realId),
      score: score,
    );
  }

  bool _heuristicNeedTools(String lower) {
    lower = lower.toLowerCase();
    const keys = [
      'hitung',
      'cari',
      'baca',
      'tulis',
      'jalankan',
      'waktu',
      'tanggal',
      'file',
      'folder',
      'web',
      'shell',
      'jadwal',
      'tool',
      'calc',
    ];
    return keys.any(lower.contains);
  }
}

class DecisionThresholds {
  const DecisionThresholds({
    this.needTool = 0.6,
    this.dangerConfirm = 0.5,
    this.dangerReject = 0.9,
  });

  final double needTool;
  final double dangerConfirm;
  final double dangerReject;
}
