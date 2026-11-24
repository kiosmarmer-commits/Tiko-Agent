import 'dart:convert';
import 'dart:io';

/// Content of the lock file (PRD §5 Lifecycle: PID, port, profile, version).
class LockInfo {
  const LockInfo({
    required this.pid,
    required this.profile,
    required this.version,
    required this.startedAt,
    this.port,
  });

  final int pid;
  final int? port;
  final String profile;
  final String version;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'port': port,
        'profile': profile,
        'version': version,
        'started_at': startedAt.toIso8601String(),
      };

  static LockInfo? tryParse(String text) {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      return LockInfo(
        pid: (j['pid'] as num).toInt(),
        port: (j['port'] as num?)?.toInt(),
        profile: j['profile'] as String? ?? 'default',
        version: j['version'] as String? ?? '',
        startedAt: DateTime.tryParse(j['started_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }
}

class LockHeldException implements Exception {
  LockHeldException(this.info);
  final LockInfo info;

  @override
  String toString() =>
      'Tiko sudah berjalan (pid ${info.pid}, port ${info.port ?? '-'}, '
      'profile ${info.profile}). Gunakan instance itu atau `tiko daemon stop`.';
}

/// Single-instance lock per profile (PRD §5, acceptance: a second process must
/// not crash with a confusing port error). Never kills foreign processes.
class RuntimeLock {
  RuntimeLock(this.path);
  final String path;

  Future<LockInfo?> read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    return LockInfo.tryParse(await f.readAsString());
  }

  /// True when a process with [pid] exists (POSIX `kill -0`; Linux/Termux/macOS).
  /// A zombie answers `kill -0` but is dead for every practical purpose, so on
  /// Linux the kernel state flag in `/proc/<pid>/stat` is checked as well.
  static bool isAlive(int pid) {
    if (pid <= 0) return false;
    try {
      if (Platform.isWindows) {
        final result = Process.runSync(
          'tasklist',
          ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH'],
        );
        return result.exitCode == 0 && result.stdout.toString().contains('"$pid"');
      }
      if (Process.runSync('kill', ['-0', '$pid']).exitCode != 0) return false;
      return !_isZombie(pid);
    } catch (_) {
      // Unknown process state is not proof that the owner is dead.
      return true;
    }
  }

  /// Linux only: state flag from `/proc/<pid>/stat`, parsed after the final
  /// `)` so command names containing spaces cannot shift the field. Returns
  /// false when the entry cannot be read (non-Linux, race with process exit).
  static bool _isZombie(int pid) {
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      final closeParen = stat.lastIndexOf(')');
      if (closeParen < 0 || closeParen + 2 >= stat.length) return false;
      return stat.codeUnitAt(closeParen + 2) == 0x5A; // 'Z'
    } catch (_) {
      return false;
    }
  }

  /// Creates the lock exclusively. Reclaims a stale lock (dead pid) once.
  /// Throws [LockHeldException] when a live instance owns it.
  Future<void> acquire({
    required String profile,
    required String version,
    int? port,
  }) async {
    final info = LockInfo(
      pid: pid,
      port: port,
      profile: profile,
      version: version,
      startedAt: DateTime.now().toUtc(),
    );
    await File(path).parent.create(recursive: true);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final f = File(path);
        f.createSync(exclusive: true);
        await f.writeAsString(jsonEncode(info.toJson()), flush: true);
        return;
      } on FileSystemException {
        final held = await read();
        if (held == null) {
          throw StateError(
            'Lock ada tetapi tidak dapat dibaca; tidak dihapus otomatis: $path',
          );
        }
        if (held.pid == pid || isAlive(held.pid)) {
          throw LockHeldException(held);
        }
        // A valid lock owned by a dead process is safe to reclaim once.
        try {
          await File(path).delete();
        } catch (_) {} // best-effort
      }
    }
    throw StateError('Gagal mengambil lock: $path');
  }

  Future<void> release() async {
    final held = await read();
    // Fail closed: an unreadable/partial lock is not proof of ownership.
    // Never delete a lock unless its recorded PID is this process.
    if (held == null || held.pid != pid) return;
    try {
      await File(path).delete();
    } catch (_) {} // best-effort
  }
}
