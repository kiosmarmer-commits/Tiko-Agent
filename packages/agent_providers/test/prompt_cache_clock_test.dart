import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 26, 12, 0, 0);

  test('clock mencatat TTL per tier dan menghitung sisa window terpanjang',
      () {
    final clock = PromptCacheClock();
    clock.record('k1', t0, ['5m', '1h']);

    expect(clock.isWarm('k1', t0.add(const Duration(minutes: 4))), isTrue);
    final w30 = clock.cacheWindow('k1', t0.add(const Duration(minutes: 30)));
    // Tier 5m sudah mati; tersisa tier 1h → ±30 menit.
    expect(w30, isNotNull);
    expect(w30!.inMinutes, closeTo(30, 1));
    expect(clock.isWarm('k1', t0.add(const Duration(minutes: 61))), isFalse);
  });

  test('tier tidak dikenal diabaikan', () {
    final clock = PromptCacheClock();
    clock.record('k', t0, ['7d', '']);
    expect(clock.cacheWindow('k', t0), isNull);
  });

  test('entri kedaluwarsa dibuang dari clock', () {
    final clock = PromptCacheClock();
    clock.record('k', t0, ['5m']);
    clock.cacheWindow('k', t0.add(const Duration(minutes: 6)));
    expect(clock.isWarm('k', t0.add(const Duration(minutes: 1))), isFalse);
  });

  test('PromptCacheManager: provenTiers mengisi clock', () {
    final manager = PromptCacheManager();
    final key = manager.cacheKey(
      model: 'claude',
      systemPrompt: 'x' * 128,
    );
    manager.markCached(key, t0, provenTiers: ['12h']);
    // Clock per tier (12h) mengalahkan config.ttl default (1 jam): masih
    // hangat pada +70 menit, window tersisa ±10 jam 50 menit.
    expect(manager.clock.isWarm(key, t0.add(const Duration(minutes: 70))),
        isTrue);
    expect(
      manager.cacheWindow(key, t0.add(const Duration(minutes: 70)))!
          .inMinutes,
      closeTo(10 * 60 + 50, 1),
    );
  });

  test('PromptCacheManager: tanpa tier, fallback ke config.ttl', () {
    final manager = PromptCacheManager(
      config: const PromptCacheConfig(ttl: Duration(hours: 2)),
    );
    final key = manager.cacheKey(model: 'm', systemPrompt: 'y' * 128);
    manager.markCached(key, t0);
    expect(
      manager.cacheWindow(key, t0.add(const Duration(hours: 1)))!.inHours,
      1,
    );
    expect(
      manager.cacheWindow(key, t0.add(const Duration(hours: 3))),
      isNull,
    );
  });

  test('observe meneruskan provenTiers ke clock', () {
    final manager = PromptCacheManager();
    manager.observe(
      model: 'm',
      systemPrompt: 'z' * 128,
      now: t0,
      provenTiers: ['30m'],
    );
    final key = manager.cacheKey(model: 'm', systemPrompt: 'z' * 128);
    expect(manager.clock.isWarm(key, t0.add(const Duration(minutes: 29))),
        isTrue);
    expect(manager.clock.isWarm(key, t0.add(const Duration(minutes: 31))),
        isFalse);
  });

  test('reset membersihkan clock dan prefix', () {
    final manager = PromptCacheManager();
    final key = manager.cacheKey(model: 'm', systemPrompt: 'w' * 128);
    manager.markCached(key, t0, provenTiers: ['1h']);
    manager.reset();
    expect(manager.cacheWindow(key, t0), isNull);
    expect(manager.clock.isWarm(key, t0.add(const Duration(seconds: 1))),
        isFalse);
  });
}
