import 'dart:convert';
import 'dart:math' as math;

/// Cross-session prompt caching (Hermes-style).
///
/// Two pieces:
/// 1. [PromptCacheManager] — tracks which stable prompt prefixes (system
///    prompt + toolset + model) were seen recently, with a 1-hour TTL and
///    hit/miss statistics. Hosts consult it before issuing a request to
///    decide whether to attach cache markers.
/// 2. [AnthropicCacheBreaker] — builds Anthropic-style `system` content
///    blocks with `cache_control: {"type": "ephemeral"}` breakpoints (max
///    4, per provider limits) so Claude reuses the cached prefix.
///
/// Pure and deterministic; no network, no I/O.

class PromptCacheConfig {
  const PromptCacheConfig({
    this.ttl = const Duration(hours: 1),
    this.minPrefixChars = 64,
    this.maxEntries = 512,
  });

  /// Provider prefix-cache lifetime (Anthropic: 1 hour, sliding).
  final Duration ttl;

  /// Prefixes shorter than this are not worth caching.
  final int minPrefixChars;
  final int maxEntries;
}

/// Prompt-cache clock (Hermes `prompt_cache_clock.py`): sampai kapan prefix
/// prompt sesi ini tetap hangat, per tier TTL yang dibuktikan response.
///
/// Satu record per attempt sukses yang membaca/menulis cache: tier yang
/// diminta (dari payload) dan tier yang dibuktikan response (Anthropic
/// `ephemeral_5m/1h_input_tokens`, OpenAI Responses `ttl_30m/12h_tokens`).
/// Setiap konsumen (indikator `/context`, keep-alive, cold-cache pruning,
/// idle compaction) membaca [cacheWindow] alih-alih menurunkan TTL sendiri.
class PromptCacheClock {
  /// TTL per tier cache. Tier mengikuti spesifikasi API, bukan vendor.
  static const Map<String, Duration> tierTtl = {
    '5m': Duration(minutes: 5),
    '30m': Duration(minutes: 30),
    '1h': Duration(hours: 1),
    '12h': Duration(hours: 12),
  };

  final Map<String, Map<String, DateTime>> _deadline = {};

  /// Mencatat satu attempt yang membaca/menulis cache: untuk [key], tier
  /// pada [provenTiers] dianggap hangat sampai [at] + TTL tier.
  void record(String key, DateTime at, Iterable<String> provenTiers) {
    if (key.isEmpty) return;
    final utc = at.toUtc();
    for (final tier in provenTiers) {
      final ttl = tierTtl[tier];
      if (ttl == null) continue;
      _deadline.putIfAbsent(key, () => {})[tier] = utc.add(ttl);
    }
  }

  /// Sisa waktu cache hangat terpanjang untuk [key] pada [now], atau null
  /// bila tidak ada tier yang masih valid. Entri kedaluwarsa dibuang.
  Duration? cacheWindow(String key, DateTime now) {
    final tiers = _deadline[key];
    if (tiers == null || tiers.isEmpty) return null;
    final utc = now.toUtc();
    Duration? best;
    tiers.removeWhere((_, deadline) => !utc.isBefore(deadline));
    for (final deadline in tiers.values) {
      final remaining = deadline.difference(utc);
      if (best == null || remaining > best) best = remaining;
    }
    if (tiers.isEmpty) _deadline.remove(key);
    return best;
  }

  /// True bila ada tier yang masih hangat untuk [key] pada [now].
  bool isWarm(String key, DateTime now) => cacheWindow(key, now) != null;

  void reset() => _deadline.clear();
}

/// Hit/miss counters for observability.
class PromptCacheStats {
  int hits = 0;
  int misses = 0;
  int evictions = 0;

  int get requests => hits + misses;

  double get hitRate => requests == 0 ? 0 : hits / requests;

  Map<String, dynamic> toJson() => {
        'hits': hits,
        'misses': misses,
        'evictions': evictions,
        'requests': requests,
        'hit_rate': hitRate,
      };
}

/// Tracks cached prompt prefixes across sessions.
class PromptCacheManager {
  PromptCacheManager({this.config = const PromptCacheConfig()});

  final PromptCacheConfig config;
  final PromptCacheStats stats = PromptCacheStats();
  final Map<String, DateTime> _cachedAt = {};

  /// Clock TTL per tier (Hermes prompt-cache clock): sumber kebenaran
  /// "sampai kapan hangat" bila tier dibuktikan response; fallback ke
  /// [PromptCacheConfig.ttl] bila tidak ada tier tercatat.
  final PromptCacheClock clock = PromptCacheClock();

  /// Stable cache key for a request prefix. Only the stable parts are
  /// hashed (model, system prompt, toolset) — not the volatile
  /// conversation tail.
  String cacheKey({
    required String model,
    required String systemPrompt,
    String toolsetHash = '',
  }) {
    final payload = jsonEncode([model, systemPrompt, toolsetHash]);
    return payload.hashCode.toRadixString(16);
  }

  /// Whether [key] was marked cached within [config.ttl] as of [now].
  /// Records a hit or miss in [stats].
  bool isCached(String key, DateTime now) {
    final at = _cachedAt[key];
    if (at == null) {
      stats.misses++;
      return false;
    }
    if (now.toUtc().isAfter(at.add(config.ttl))) {
      _cachedAt.remove(key);
      stats.misses++;
      return false;
    }
    stats.hits++;
    return true;
  }

  /// Marks [key] as cached at [now] if the prefix is long enough to be
  /// worth caching. Applies LRU-style eviction beyond [config.maxEntries].
  /// [provenTiers] (mis. `['5m', '1h']`) memperbarui clock per tier bila
  /// response provider membuktikan tier tersebut.
  void markCached(
    String key,
    DateTime now, {
    Iterable<String> provenTiers = const [],
  }) {
    if (key.isEmpty) return;
    _cachedAt[key] = now.toUtc();
    if (provenTiers.isNotEmpty) clock.record(key, now, provenTiers);
    while (_cachedAt.length > config.maxEntries) {
      final oldest = _cachedAt.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
      _cachedAt.remove(oldest.key);
      stats.evictions++;
    }
  }

  /// Convenience: key + lookup + mark in one call. Returns true when the
  /// prefix was already cached (and thus reusable).
  bool observe({
    required String model,
    required String systemPrompt,
    String toolsetHash = '',
    DateTime? now,
    Iterable<String> provenTiers = const [],
  }) {
    if (systemPrompt.length < config.minPrefixChars) {
      stats.misses++;
      return false;
    }
    final at = (now ?? DateTime.now()).toUtc();
    final key = cacheKey(
        model: model, systemPrompt: systemPrompt, toolsetHash: toolsetHash);
    final wasCached = isCached(key, at);
    markCached(key, at, provenTiers: provenTiers);
    return wasCached;
  }

  /// Sisa waktu hangat untuk prefix [key] pada [now]: dari clock per tier
  /// bila ada tier terbukti, otherwise dari [config.ttl] sejak mark.
  Duration? cacheWindow(String key, DateTime? now) {
    if (key.isEmpty) return null;
    final at = (now ?? DateTime.now()).toUtc();
    final proven = clock.cacheWindow(key, at);
    if (proven != null) return proven;
    final marked = _cachedAt[key];
    if (marked == null) return null;
    final remaining = marked.add(config.ttl).difference(at);
    return remaining <= Duration.zero ? null : remaining;
  }

  void reset() {
    _cachedAt.clear();
    clock.reset();
  }
}

/// Builds Anthropic-style cached system blocks.
class AnthropicCacheBreaker {
  const AnthropicCacheBreaker({this.maxBreakpoints = 4});

  /// Anthropic allows up to 4 cache breakpoints per request.
  final int maxBreakpoints;

  /// Returns the `system` payload: a single text block with an
  /// `ephemeral` cache_control breakpoint, or a plain string when
  /// [enabled] is false.
  Object buildSystem(String systemPrompt, {bool enabled = true}) {
    if (!enabled || systemPrompt.isEmpty) return systemPrompt;
    return [
      {
        'type': 'text',
        'text': systemPrompt,
        'cache_control': {'type': 'ephemeral'},
      },
    ];
  }

  /// Splits a long system prompt into at most [maxBreakpoints] blocks,
  /// each with a cache_control marker, so prefix growth invalidates only
  /// the tail block. Deterministic split on paragraph boundaries.
  List<Map<String, dynamic>> buildBlocks(String systemPrompt) {
    if (systemPrompt.isEmpty) return const [];
    final paragraphs = systemPrompt
        .split(RegExp(r'\n\s*\n'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (paragraphs.length <= maxBreakpoints) {
      return [
        for (final para in paragraphs)
          {
            'type': 'text',
            'text': para,
            'cache_control': {'type': 'ephemeral'},
          },
      ];
    }
    final perBucket = (paragraphs.length / maxBreakpoints).ceil();
    final blocks = <Map<String, dynamic>>[];
    for (var i = 0; i < paragraphs.length; i += perBucket) {
      final chunk = paragraphs
          .skip(i)
          .take(perBucket)
          .join('\n\n');
      blocks.add({
        'type': 'text',
        'text': chunk,
        'cache_control': {'type': 'ephemeral'},
      });
      if (blocks.length == maxBreakpoints) break;
    }
    return blocks;
  }

  /// Estimated saved tokens given cached and fresh prompt token counts.
  /// Anthropic bills cache reads at ~10% of base input price.
  double estimatedSavings(int cachedTokens, int freshTokens,
      {double cacheReadFactor = 0.1}) {
    if (cachedTokens < 0 || freshTokens < 0) return 0;
    return math.max(0.0, cachedTokens.toDouble() * (1 - cacheReadFactor));
  }
}
