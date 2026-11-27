// Hermes parity: deadline turn monotonik. Berbeda dari cek wall-clock
// [BudgetGuard] (DateTime.now — bisa melompat saat NTP/suspend, dan hanya
// dicek di puncak loop), [TurnDeadline] memakai [Stopwatch] monotonik dan
// diekspos ke pemanggil (remaining/isExpired) agar AgentLoop bisa melewati
// ronde tool baru saat waktu turn sudah habis.
library;

import 'dart:core';

/// Deadline monotonik untuk satu turn agent. Never-raises; `off` menandai
/// deadline dinonaktifkan (isExpired selalu false, remaining null).
class TurnDeadline {
  TurnDeadline(Duration budget)
      : _budget = budget,
        _sw = Stopwatch()..start();

  /// Deadline dinonaktifkan (0 = off, konvensi config runtime).
  factory TurnDeadline.off() => TurnDeadline(Duration.zero);

  final Duration _budget;
  final Stopwatch _sw;

  /// Apakah deadline aktif (> 0 detik).
  bool get enabled => _budget > Duration.zero;

  /// True bila waktu turn sudah habis (selalu false bila off).
  bool get isExpired => enabled && _sw.elapsed >= _budget;

  /// Sisa waktu; null bila off.
  Duration? remaining() => enabled
      ? (_sw.elapsed >= _budget ? Duration.zero : _budget - _sw.elapsed)
      : null;
}
