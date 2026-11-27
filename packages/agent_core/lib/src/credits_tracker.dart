/// Credits tracker (Hermes parity: `agent/credits_tracker.py`): akumulasi
/// biaya USD harian dengan limit opsional; fail-open dan tidak pernah
/// melempar. Limit 0 = off (hanya observability).
library;

/// Tracker kredit harian (Hermes parity: `agent/credits_tracker.py`):
/// akumulasi biaya USD per hari UTC dengan limit opsional; fail-open dan
/// tidak pernah melempar. Limit 0 = off (hanya observability).
class CreditsTracker {
  CreditsTracker({
    this.dailyLimitUsd = 0,
    this.warnRatio = 0.8,
    String Function()? dayKey,
  }) : _dayKey = dayKey ?? (() => DateTime.now().toUtc().toIso8601String().substring(0, 10));

  /// Limit pengeluaran USD per hari UTC; 0 = tanpa limit.
  final double dailyLimitUsd;

  /// Fraksi limit tempat peringatan sekali per hari dikeluarkan.
  final double warnRatio;
  final String Function() _dayKey;

  String _day = '';
  double _spent = 0;
  bool _warnedToday = false;

  void _rollover() {
    final day = _dayKey();
    if (day != _day) {
      _day = day;
      _spent = 0;
      _warnedToday = false;
    }
  }

  /// Catat biaya turn (USD, ≥0; negatif diabaikan).
  void recordCost(double usd) {
    if (usd.isNaN || usd <= 0) return;
    _rollover();
    _spent += usd;
  }

  double get spentToday {
    _rollover();
    return _spent;
  }

  /// Sisa kredit hari ini; null bila tanpa limit.
  double? get remaining {
    if (dailyLimitUsd <= 0) return null;
    _rollover();
    final r = dailyLimitUsd - _spent;
    return r < 0 ? 0 : r;
  }

  /// True bila limit harian aktif dan sudah tercapai/terlewati.
  bool get exceeded {
    if (dailyLimitUsd <= 0) return false;
    _rollover();
    return _spent >= dailyLimitUsd;
  }

  /// Sinyal peringatan sekali per hari saat mencapai [warnRatio] × limit;
  /// false berarti tidak ada peringatan (tanpa limit, atau sudah dipakai).
  bool consumeWarnSignal() {
    if (dailyLimitUsd <= 0) return false;
    _rollover();
    if (_warnedToday) return false;
    if (_spent < dailyLimitUsd * warnRatio) return false;
    _warnedToday = true;
    return true;
  }
}
