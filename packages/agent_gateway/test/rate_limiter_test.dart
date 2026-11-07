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
}
