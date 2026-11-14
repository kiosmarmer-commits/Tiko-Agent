/// Resource monitor and power-saver gate (AI-U03, AI-U04).
///
/// Reads memory / load from procfs when available and answers the single
/// question the power-saver mode needs: may heavy AI work (embedding, LLM)
/// run right now? Everything is injectable so tests never touch /proc.
library;

import 'dart:io';

/// One resource snapshot. Values are null when the platform does not
/// expose them (web, macOS/Windows without procfs).
class ResourceSnapshot {
  const ResourceSnapshot({
    required this.rssMb,
    required this.cpuCount,
    required this.loadAvg1,
    this.cpuTicks,
  });

  /// Resident set size of the current process, in MiB.
  final double? rssMb;
  final int cpuCount;

  /// 1-minute load average (Linux).
  final double? loadAvg1;

  /// Cumulative process CPU time in jiffies (utime+stime from
  /// /proc/self/stat). Delta between two snapshots over a known interval
  /// yields CPU usage via [ResourceMonitor.cpuPercent].
  final int? cpuTicks;

  Map<String, Object?> toJson() => {
        if (rssMb != null) 'rss_mb': rssMb,
        'cpu_count': cpuCount,
        if (loadAvg1 != null) 'load_avg_1': loadAvg1,
        if (cpuTicks != null) 'cpu_ticks': cpuTicks,
      };
}

abstract final class ResourceMonitor {
  /// Reads /proc/self/status + /proc/loadavg; null fields when unreadable.
  static ResourceSnapshot snapshot() {
    return ResourceSnapshot(
      rssMb: _rssMb(),
      cpuCount: Platform.numberOfProcessors,
      loadAvg1: _loadAvg(),
      cpuTicks: _cpuTicks(),
    );
  }

  /// Process CPU usage in percent between two snapshots taken
  /// [intervalSeconds] apart. Assumes the Linux-standard 100 Hz jiffy clock;
  /// returns null when either snapshot lacks cpu ticks or the interval is
  /// not positive.
  static double? cpuPercent(
    ResourceSnapshot previous,
    ResourceSnapshot current, {
    required double intervalSeconds,
  }) {
    final prev = previous.cpuTicks;
    final curr = current.cpuTicks;
    if (prev == null || curr == null || intervalSeconds <= 0) return null;
    final delta = curr - prev;
    if (delta < 0) return null;
    return (delta / (intervalSeconds * clockTicksPerSecond)) * 100;
  }

  /// Linux userland clock tick rate (CLK_TCK is 100 on every mainstream
  /// kernel; procfs does not expose it directly).
  static const int clockTicksPerSecond = 100;

  static int? _cpuTicks() {
    try {
      final stat = File('/proc/self/stat');
      if (!stat.existsSync()) return null;
      final raw = stat.readAsStringSync();
      final afterComm = raw.lastIndexOf(')');
      if (afterComm < 0 || afterComm + 2 > raw.length) return null;
      final fields = raw.substring(afterComm + 2).split(' ');
      if (fields.length < 13) return null;
      final utime = int.tryParse(fields[11]);
      final stime = int.tryParse(fields[12]);
      if (utime == null || stime == null) return null;
      return utime + stime;
    } on FileSystemException {
      return null;
    }
  }

  static double? _rssMb() {
    try {
      final status = File('/proc/self/status');
      if (!status.existsSync()) return null;
      for (final line in status.readAsLinesSync()) {
        if (line.startsWith('VmRSS:')) {
          final kb = int.tryParse(
              line.replaceAll(RegExp(r'[^0-9]'), ''));
          if (kb != null) return kb / 1024.0;
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  static double? _loadAvg() {
    try {
      final loadavg = File('/proc/loadavg');
      if (!loadavg.existsSync()) return null;
      final first = loadavg.readAsLinesSync().first.split(' ').first;
      return double.tryParse(first);
    } on FileSystemException {
      return null;
    }
  }

  /// Detects external power from sysfs (Linux laptops/phones). Returns null
  /// when no battery/AC info exists — treated as "plugged" so desktop
  /// machines are never blocked by power-saver mode.
  static bool? isPluggedIn() {
    try {
      final dir = Directory('/sys/class/power_supply');
      if (!dir.existsSync()) return null;
      for (final supply in dir.listSync()) {
        final online = File('${supply.path}/online');
        if (online.existsSync()) {
          final value = int.tryParse(online.readAsStringSync().trim());
          if (value != null && value > 0) return true;
        }
      }
      return false;
    } on FileSystemException {
      return null;
    }
  }
}

/// Central gate for heavy AI work (AI-U04): when power saver is enabled and
/// the device is on battery, embedding/LLM runs are deferred.
class PowerSaverGate {
  PowerSaverGate({bool? Function()? pluggedIn})
      : _pluggedIn = pluggedIn ?? ResourceMonitor.isPluggedIn;

  final bool? Function()? _pluggedIn;

  /// True when heavy work may run now.
  bool allowsWork({required bool powerSaverEnabled}) {
    if (!powerSaverEnabled) return true;
    final plugged = _pluggedIn?.call();
    return plugged == null || plugged;
  }
}
