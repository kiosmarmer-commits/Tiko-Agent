/// Simple per-user rate limiter (AGD-05 §2).
///
/// Memori terbatas: entri user yang idle lebih dari satu jendela dipangkas
/// oleh sweep berkala (maks. sekali per jendela), dan jumlah user terlacak
/// di-cap pada [maxTrackedUsers] — saat cap terlampaui, user dengan hit
/// terbaru paling tua di-evict (trade-off yang disengaja: banjir key unik
/// bisa menggeser pelacakan, tapi memori tetap terikat).
class RateLimiter {
  RateLimiter({
    this.maxPerMinute = 20,
    this.maxTrackedUsers = 10000,
    DateTime Function()? clock,
  }) : clock = clock ?? _systemNow;

  final int maxPerMinute;
  final int maxTrackedUsers;
  final DateTime Function() clock;
  final _hits = <String, List<DateTime>>{};
  DateTime? _lastSweep;

  static DateTime _systemNow() => DateTime.now().toUtc();

  /// Jumlah user yang sedang dilacak (observability/test).
  int get trackedUsers => _hits.length;

  bool allow(String userKey) {
    final now = clock();
    final window = now.subtract(const Duration(minutes: 1));
    final lastSweep = _lastSweep;
    if (lastSweep == null || now.difference(lastSweep) >= const Duration(minutes: 1)) {
      _sweep(window);
      _lastSweep = now;
    }
    final list = _hits.putIfAbsent(userKey, () => []);
    list.removeWhere((t) => t.isBefore(window));
    if (list.length >= maxPerMinute) return false;
    list.add(now);
    if (_hits.length > maxTrackedUsers) _evictOldest();
    return true;
  }

  void _sweep(DateTime window) {
    _hits.removeWhere((_, list) {
      list.removeWhere((t) => t.isBefore(window));
      return list.isEmpty;
    });
  }

  void _evictOldest() {
    while (_hits.length > maxTrackedUsers) {
      String? oldestKey;
      DateTime? oldestHit;
      _hits.forEach((key, list) {
        final newest = list.isEmpty ? null : list.last;
        if (oldestHit == null || (newest != null && newest.isBefore(oldestHit!))) {
          oldestKey = key;
          oldestHit = newest;
        }
      });
      if (oldestKey == null) break;
      _hits.remove(oldestKey);
    }
  }
}
