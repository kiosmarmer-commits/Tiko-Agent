/// Simple per-user rate limiter (AGD-05 §2).
class RateLimiter {
  RateLimiter({this.maxPerMinute = 20});

  final int maxPerMinute;
  final _hits = <String, List<DateTime>>{};

  bool allow(String userKey) {
    final now = DateTime.now().toUtc();
    final window = now.subtract(const Duration(minutes: 1));
    final list = _hits.putIfAbsent(userKey, () => []);
    list.removeWhere((t) => t.isBefore(window));
    if (list.length >= maxPerMinute) return false;
    list.add(now);
    return true;
  }
}
