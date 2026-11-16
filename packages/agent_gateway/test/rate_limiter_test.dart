import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('rate limiter blocks after max', () {
    final r = RateLimiter(maxPerMinute: 3);
    expect(r.allow('u1'), isTrue);
    expect(r.allow('u1'), isTrue);
    expect(r.allow('u1'), isTrue);
    expect(r.allow('u1'), isFalse);
    expect(r.allow('u2'), isTrue);
  });

  test('sweep memangkas user idle lebih dari satu jendela', () {
    var now = DateTime.utc(2026, 11, 16, 8);
    final r = RateLimiter(maxPerMinute: 3, clock: () => now);

    r.allow('u1');
    r.allow('u2');
    expect(r.trackedUsers, 2);

    now = now.add(const Duration(seconds: 30));
    r.allow('u1');
    expect(r.trackedUsers, 2);

    now = now.add(const Duration(seconds: 61));
    r.allow('u3');
    expect(r.trackedUsers, 1, reason: 'u1 dan u2 idle > 1 menit dipangkas');
    expect(r.allow('u1'), isTrue, reason: 'limit u1 reset setelah idle');
  });

  test('sweep mempertahankan user aktif dalam jendela', () {
    var now = DateTime.utc(2026, 11, 16, 8);
    final r = RateLimiter(maxPerMinute: 5, clock: () => now);

    r.allow('u0');
    r.allow('u1');
    now = now.add(const Duration(seconds: 50));
    r.allow('u1');
    r.allow('u2');

    now = now.add(const Duration(seconds: 55));
    r.allow('u3');
    expect(r.trackedUsers, 3,
        reason: 'u0 idle dipangkas; u1 (hit 45s lalu) dan u2 dipertahankan');
  });

  test('cap maxTrackedUsers meng-evict user dengan hit tertua', () {
    var now = DateTime.utc(2026, 11, 16, 8);
    final r = RateLimiter(
      maxPerMinute: 3,
      maxTrackedUsers: 2,
      clock: () => now,
    );

    r.allow('u1');
    now = now.add(const Duration(seconds: 10));
    r.allow('u2');
    now = now.add(const Duration(seconds: 10));
    r.allow('u3');

    expect(r.trackedUsers, 2);
    expect(r.allow('u1'), isTrue,
        reason: 'u1 ter-evict sehingga limitnya reset (trade-off cap)');
  });
}
