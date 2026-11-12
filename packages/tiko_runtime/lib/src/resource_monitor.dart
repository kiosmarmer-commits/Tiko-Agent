import 'dart:io';

/// Host resource snapshot for eco/Termux (PRD P3).
class ResourceSnapshot {
  ResourceSnapshot({
    this.memAvailableMb,
    this.memTotalMb,
    this.diskFreeMb,
    this.isTermux = false,
    this.hasSqliteNative = false,
    this.networkLikely = true,
    this.profile = 'standard',
  });

  final int? memAvailableMb;
  final int? memTotalMb;
  final int? diskFreeMb;
  final bool isTermux;
  final bool hasSqliteNative;
  final bool networkLikely;
  final String profile;

  Map<String, dynamic> toJson() => {
        'mem_available_mb': memAvailableMb,
        'mem_total_mb': memTotalMb,
        'disk_free_mb': diskFreeMb,
        'is_termux': isTermux,
        'has_sqlite_native': hasSqliteNative,
        'network_likely': networkLikely,
        'profile': profile,
      };
}

class ResourceMonitor {
  static const int ecoRamMb = 768;
  static const int criticalRamMb = 512;
  static const int criticalDiskMb = 100;

  static ResourceSnapshot capture({String? dataDir}) {
    final termux = Platform.environment.containsKey('TERMUX_VERSION') ||
        Platform.environment['PREFIX']?.contains('com.termux') == true ||
        Directory('/data/data/com.termux').existsSync();

    int? memAvail;
    int? memTotal;
    try {
      final f = File('/proc/meminfo');
      if (f.existsSync()) {
        for (final line in f.readAsLinesSync()) {
          if (line.startsWith('MemAvailable:')) {
            memAvail = int.tryParse(line.split(RegExp(r'\s+'))[1])! ~/ 1024;
          }
          if (line.startsWith('MemTotal:')) {
            memTotal = int.tryParse(line.split(RegExp(r'\s+'))[1])! ~/ 1024;
          }
        }
      }
    } catch (_) {}

    int? diskFree;
    try {
      final path = dataDir ?? Directory.current.path;
      // `df -k` portable-ish
      final r = Process.runSync('df', ['-k', path]);
      if (r.exitCode == 0) {
        final lines = (r.stdout as String).trim().split('\n');
        if (lines.length >= 2) {
          final parts = lines.last.split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            diskFree = int.tryParse(parts[3])! ~/ 1024;
          }
        }
      }
    } catch (_) {}

    var hasSqlite = false;
    try {
      // probe common lib names
      for (final lib in [
        'libsqlite3.so',
        '/system/lib64/libsqlite3.so',
        '${Platform.environment['PREFIX'] ?? ''}/lib/libsqlite3.so',
      ]) {
        if (lib.isEmpty) continue;
        if (File(lib).existsSync()) {
          hasSqlite = true;
          break;
        }
      }
      if (!hasSqlite && Platform.isLinux) {
        final r = Process.runSync('ldconfig', ['-p']);
        if ((r.stdout as String).contains('libsqlite3.so')) hasSqlite = true;
      }
    } catch (_) {}

    var network = true;
    try {
      // offline heuristic: no default route
      final r = Process.runSync('sh', ['-c', 'ip route 2>/dev/null | head -1']);
      if (r.exitCode == 0 && (r.stdout as String).trim().isEmpty) {
        network = false;
      }
    } catch (_) {}

    var profile = 'standard';
    if (memAvail != null && memAvail < ecoRamMb) {
      profile = 'eco';
    } else if (memAvail != null && memAvail > 4096 && !termux) {
      profile = 'power';
    }
    if (termux && profile == 'power') profile = 'standard';

    return ResourceSnapshot(
      memAvailableMb: memAvail,
      memTotalMb: memTotal,
      diskFreeMb: diskFree,
      isTermux: termux,
      hasSqliteNative: hasSqlite,
      networkLikely: network,
      profile: profile,
    );
  }
}
