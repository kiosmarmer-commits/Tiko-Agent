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
  void markCached(String key, DateTime now) {
    if (key.isEmpty) return;
    _cachedAt[key] = now.toUtc();
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
  }) {
    if (systemPrompt.length < config.minPrefixChars) {
      stats.misses++;
      return false;
    }
    final at = (now ?? DateTime.now()).toUtc();
    final key = cacheKey(
        model: model, systemPrompt: systemPrompt, toolsetHash: toolsetHash);
    final wasCached = isCached(key, at);
    markCached(key, at);
    return wasCached;
  }

  void reset() {
    _cachedAt.clear();
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
