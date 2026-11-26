/// Side question lease (Hermes `agent/side_question_lease.py`): /btw berjalan
/// DI LUAR lock sesi utama (turn utama boleh tetap aktif), jadi konkurensi
/// dijaga lease terpisah per sesi — hanya satu side question aktif, kedaluwarsa
/// otomatis (TTL) agar crash pemegang tidak mengunci /btw selamanya.
library;

/// Lease konkurensi untuk side question per sesi.
class SideQuestionLease {
  SideQuestionLease({this.defaultTtlSec = 120});

  /// TTL default: side question one-shot seharusnya selesai jauh lebih
  /// cepat; kedaluwarsa mencegah lease yatim mengunci selamanya.
  final int defaultTtlSec;

  final Map<String, ({String owner, double expiresAt})> _held = {};

  /// True bila [sessionId] sedang dipegang lease yang belum kedaluwarsa.
  bool isHeld(String sessionId, {required double Function() clock}) {
    final e = _held[sessionId];
    if (e == null) return false;
    if (clock() >= e.expiresAt) {
      _held.remove(sessionId);
      return false;
    }
    return true;
  }

  /// Coba pegang lease; false bila sudah dipegang pemegang hidup lain.
  bool tryAcquire(
    String sessionId, {
    required String owner,
    required double Function() clock,
    int? ttlSec,
  }) {
    if (isHeld(sessionId, clock: clock)) return false;
    final ttl = (ttlSec ?? defaultTtlSec).clamp(1, 3600);
    _held[sessionId] = (
      owner: owner,
      expiresAt: clock() + ttl,
    );
    return true;
  }

  /// Lepas lease hanya bila pemegangnya [owner] (bukan pemegang yatim yang
  /// sudah digantikan). Return true bila lease benar-benar dilepas.
  bool release(String sessionId, {required String owner}) {
    final e = _held[sessionId];
    if (e == null || e.owner != owner) return false;
    _held.remove(sessionId);
    return true;
  }

  /// Buang semua lease yang sudah kedaluwarsa; return jumlah yang dibuang.
  int sweep({required double Function() clock}) {
    final now = clock();
    final dead = [
      for (final e in _held.entries)
        if (now >= e.value.expiresAt) e.key,
    ];
    for (final k in dead) {
      _held.remove(k);
    }
    return dead.length;
  }
}
