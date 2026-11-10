import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);
  final longSystem = 'Kamu adalah asisten. ' * 10;

  group('PromptCacheManager', () {
    test('first observe is a miss, second is a hit', () {
      final cache = PromptCacheManager();
      expect(
        cache.observe(model: 'claude', systemPrompt: longSystem, now: now),
        isFalse,
      );
      expect(
        cache.observe(model: 'claude', systemPrompt: longSystem, now: now),
        isTrue,
      );
      expect(cache.stats.hits, 1);
      expect(cache.stats.misses, 1);
    });

    test('entries expire after ttl', () {
      final cache = PromptCacheManager();
      final key = cache.cacheKey(model: 'm', systemPrompt: longSystem);
      cache.markCached(key, now);
      expect(cache.isCached(key, now), isTrue);
      expect(
        cache.isCached(key, now.add(const Duration(hours: 1, seconds: 1))),
        isFalse,
      );
    });

    test('different prefixes map to different keys', () {
      final cache = PromptCacheManager();
      final k1 = cache.cacheKey(model: 'm', systemPrompt: 'prefix A' * 20);
      final k2 = cache.cacheKey(model: 'm', systemPrompt: 'prefix B' * 20);
      expect(k1, isNot(k2));
    });

    test('short prefixes are never cached', () {
      final cache = PromptCacheManager();
      expect(
        cache.observe(model: 'm', systemPrompt: 'pendek', now: now),
        isFalse,
      );
      expect(
        cache.observe(model: 'm', systemPrompt: 'pendek', now: now),
        isFalse,
      );
      expect(cache.stats.hits, 0);
    });

    test('eviction respects maxEntries', () {
      final cache = PromptCacheManager(
          config: const PromptCacheConfig(maxEntries: 2));
      cache.markCached('a', now);
      cache.markCached('b', now.add(const Duration(seconds: 1)));
      cache.markCached('c', now.add(const Duration(seconds: 2)));
      expect(cache.stats.evictions, 1);
    });

    test('stats json round trip fields', () {
      final cache = PromptCacheManager();
      cache.observe(model: 'm', systemPrompt: longSystem, now: now);
      cache.observe(model: 'm', systemPrompt: longSystem, now: now);
      final json = cache.stats.toJson();
      expect(json['hits'], 1);
      expect(json['misses'], 1);
      expect(json['requests'], 2);
      expect(json['hit_rate'], 0.5);
    });
  });

  group('AnthropicCacheBreaker', () {
    const breaker = AnthropicCacheBreaker();

    test('buildSystem emits one ephemeral block when enabled', () {
      final system = breaker.buildSystem(longSystem);
      expect(system, isA<List<dynamic>>());
      final blocks = system as List<dynamic>;
      expect(blocks, hasLength(1));
      final block = blocks.first as Map<String, dynamic>;
      expect(block['cache_control'], {'type': 'ephemeral'});
      expect(block['text'], longSystem);
    });

    test('buildSystem returns plain string when disabled', () {
      expect(breaker.buildSystem(longSystem, enabled: false), longSystem);
      expect(breaker.buildSystem(''), '');
    });

    test('buildBlocks splits paragraphs into blocks', () {
      final blocks =
          breaker.buildBlocks('satu\n\ndua\n\ntiga\n\ne.mpat');
      expect(blocks, hasLength(4));
      for (final b in blocks) {
        expect(b['cache_control'], {'type': 'ephemeral'});
      }
    });

    test('buildBlocks caps at maxBreakpoints', () {
      final long = List.generate(9, (i) => 'paragraf $i').join('\n\n');
      final blocks = breaker.buildBlocks(long);
      expect(blocks.length, lessThanOrEqualTo(4));
      expect(blocks.last['text'], contains('paragraf 8'));
    });

    test('buildBlocks of empty prompt is empty', () {
      expect(breaker.buildBlocks(''), isEmpty);
    });

    test('estimatedSavings uses the cache-read factor', () {
      expect(breaker.estimatedSavings(1000, 0), 900.0);
      expect(breaker.estimatedSavings(0, 1000), 0.0);
      expect(breaker.estimatedSavings(-5, 0), 0.0);
    });
  });
}
