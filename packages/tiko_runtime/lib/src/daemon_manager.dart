import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'runtime_lock.dart';
import 'remote_client.dart';
import 'api_token_store.dart';

/// Start/stop/status for managed agentd process (PRD lifecycle).
class DaemonManager {
  DaemonManager({
    required this.dataDir,
    required this.apiPort,
    this.configPath = 'config/agent.yaml',
    this.safe = true,
    this.agentdEntry = 'apps/agentd/bin/agentd.dart',
    this.agentdBinary,
    this.workspaceRoot,
  });

  final String dataDir;
  final int apiPort;
  final String configPath;
  final bool safe;
  final String agentdEntry;

  /// Compiled agentd executable for self-contained launches (desktop app).
  /// When set and the file exists, the daemon is spawned directly from the
  /// binary instead of `dart run` inside a repository checkout.
  final String? agentdBinary;

  /// Working directory for the daemon process. Defaults to [findRepoRoot]
  /// (repository root) in dev mode, or the current directory when a bundled
  /// binary is used without an explicit workspace.
  final String? workspaceRoot;

  RuntimeLock get lock => RuntimeLock(p.join(dataDir, 'tiko.lock'));

  /// Pure launch-plan resolver (testable): returns the executable and argv
  /// used to start the daemon, plus the working directory.
  static ({String exe, List<String> args, String? workingDir}) launchPlan({
    required String dataDir,
    required int apiPort,
    required String configPath,
    required bool safe,
    String agentdEntry = 'apps/agentd/bin/agentd.dart',
    String? agentdBinary,
    String? workspaceRoot,
  }) {
    final useBinary = agentdBinary != null &&
        agentdBinary.isNotEmpty &&
        File(agentdBinary).existsSync();
    if (useBinary) {
      return (
        exe: agentdBinary,
        args: ['--api', if (!safe) '--no-safe'],
        workingDir: workspaceRoot,
      );
    }
    return (
      exe: 'dart',
      args: ['run', agentdEntry, '--api', if (!safe) '--no-safe'],
      workingDir: workspaceRoot ?? findRepoRoot(),
    );
  }

  /// Baca baris terakhir [maxLines] dari file log (mis. data/daemon.log)
  /// untuk disertakan pada pesan kegagalan start. Null bila kosong/tak terbaca.
  static String? tailLog(String path, {int maxLines = 40}) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final lines = file.readAsLinesSync();
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      if (lines.isEmpty) return null;
      final tail =
          lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
      return tail.join('\n');
    } catch (_) {
      return null;
    }
  }

  /// Walks up from the current directory looking for the repository root
  /// (a directory containing pubspec.yaml and apps/).
  static String? findRepoRoot() {
    Directory d = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
          Directory(p.join(d.path, 'apps')).existsSync()) {
        return d.path;
      }
      final parent = d.parent;
      if (parent.path == d.path) break;
      d = parent;
    }
    return null;
  }

  Future<Map<String, dynamic>> status() async {
    final info = await lock.read();
    if (info == null) {
      return {'running': false, 'detail': 'tidak ada lock'};
    }
    final alive = RuntimeLock.isAlive(info.pid);
    return {
      'running': alive,
      'pid': info.pid,
      'port': info.port,
      'version': info.version,
      'started_at': info.startedAt.toIso8601String(),
      'stale': !alive,
    };
  }

  Future<Map<String, dynamic>> start({Map<String, String>? environment}) async {
    final launchEnv = Map<String, String>.from(Platform.environment)
      ..addAll(environment ?? {});
    final configuredHost = launchEnv['API_HOST'] ?? '127.0.0.1';
    final healthHost = configuredHost == '0.0.0.0' || configuredHost == '::'
        ? '127.0.0.1'
        : configuredHost;
    final cur = await status();
    if (cur['running'] == true) {
      if (await _apiHealthy(healthHost, (cur['port'] as int?) ?? apiPort)) {
        return {...cur, 'action': 'reuse'};
      }
      return {
        ...cur,
        'action': 'unhealthy',
        'detail': 'lock aktif tetapi endpoint HTTP tidak sehat; periksa data/daemon.log',
      };
    }
    // clear stale lock
    final info = await lock.read();
    if (info != null && !RuntimeLock.isAlive(info.pid)) {
      try {
        await File(lock.path).delete();
      } catch (_) {} // best-effort
    }

    await Directory(dataDir).create(recursive: true);
    final logPath = p.join(dataDir, 'daemon.log');
    final log = File(logPath).openWrite(mode: FileMode.append);
    final env = launchEnv;
    final configuredToken = env['API_TOKEN']?.trim();
    if (configuredToken == null || configuredToken.isEmpty) {
      env['API_TOKEN'] = envToken();
    } else {
      env['API_TOKEN'] = configuredToken;
    }
    env['AGENT_UI'] = '1';
    // Daemon programatik: jangan auto-buka browser web dashboard.
    env['TIKO_NO_BROWSER'] = '1';
    env['API_PORT'] = '$apiPort';
    env['TIKO_CONFIG'] = p.absolute(
      workspaceRoot != null && p.isAbsolute(configPath)
          ? configPath
          : p.join(workspaceRoot ?? Directory.current.path, configPath),
    );

    final plan = launchPlan(
      dataDir: dataDir,
      apiPort: apiPort,
      configPath: configPath,
      safe: safe,
      agentdEntry: agentdEntry,
      agentdBinary: agentdBinary,
      workspaceRoot: workspaceRoot,
    );
    final proc = await Process.start(
      plan.exe,
      plan.args,
      environment: env,
      mode: ProcessStartMode.detachedWithStdio,
      workingDirectory: plan.workingDir ?? Directory.current.path,
    );
    proc.stdout.listen(log.add);
    proc.stderr.listen(log.add);

    // Deteksi kematian awal proses: agentd bisa exit segera (config invalid,
    // biner lama, `dart` tidak ada di PATH) tanpa pernah sempat menulis lock.
    var alive = true;
    unawaited(proc.exitCode.then((_) => alive = false));

    // Wait for both the process lock and the HTTP health endpoint. A lock
    // only proves that the process started; it does not prove that API bind,
    // token persistence, and runtime initialization succeeded.
    const waitMs = 250;
    const maxWait = 60;
    var exitedBeforeReady = false;
    for (var i = 0; i < maxWait; i++) {
      await Future<void>.delayed(const Duration(milliseconds: waitMs));
      final st = await status();
      if (st['running'] == true && await _apiHealthy(healthHost, apiPort)) {
        return {
          'running': true,
          'action': 'started',
          'pid': st['pid'],
          'port': apiPort,
          'log': logPath,
        };
      }
      if (!alive) {
        exitedBeforeReady = true;
        break;
      }
      if (st['running'] != true && i > 2) break;
    }
    // Pastikan seluruh output agentd ter-flush sebelum log dibaca.
    try {
      await log.close();
    } catch (_) {}
    final tail = tailLog(logPath);
    final detail = exitedBeforeReady
        ? 'proses daemon berakhir sebelum siap; log terakhir:\n${tail ?? '(log kosong)'}'
        : 'timeout menunggu daemon siap (${(maxWait * waitMs / 1000).toStringAsFixed(0)}s); '
            'log terakhir:\n${tail ?? '(log kosong)'}';
    return {
      'running': false,
      'action': exitedBeforeReady ? 'exited' : 'timeout',
      'pid': proc.pid,
      'log': logPath,
      'detail': detail,
    };
  }

  Future<Map<String, dynamic>> stop() async {
    final info = await lock.read();
    if (info == null) return {'stopped': true, 'detail': 'tidak berjalan'};
    if (!RuntimeLock.isAlive(info.pid)) {
      try {
        await File(lock.path).delete();
      } catch (_) {} // best-effort
      return {'stopped': true, 'detail': 'stale lock dibersihkan', 'pid': info.pid};
    }

    // Never signal a PID from a lock file directly: PIDs can be reused. Ask
    // the authenticated daemon API to shut itself down and let agentd release
    // its own lock after closing gateways, scheduler and HTTP resources.
    final token = await ApiTokenStore.read(dataDir, environment: const {});
    if (token == null || token.length < 32) {
      return {
        'stopped': false,
        'pid': info.pid,
        'detail': 'token lokal tidak tersedia; daemon tidak dihentikan untuk menghindari salah-kill PID',
      };
    }
    final port = info.port ?? apiPort;
    final envHost = Platform.environment['API_HOST'] ?? '127.0.0.1';
    final host = envHost == '0.0.0.0' || envHost == '::' ? '127.0.0.1' : envHost;
    final remote = TikoRemoteClient(
      baseUrl: 'http://$host:$port',
      token: token,
    );
    try {
      if (!await remote.shutdown()) {
        return {'stopped': false, 'pid': info.pid, 'detail': 'daemon menolak shutdown'};
      }
    } catch (error) {
      return {'stopped': false, 'pid': info.pid, 'detail': 'shutdown API gagal: $error'};
    }

    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final current = await lock.read();
      if (current == null || !RuntimeLock.isAlive(current.pid)) {
        return {'stopped': true, 'pid': info.pid};
      }
    }
    return {
      'stopped': false,
      'pid': info.pid,
      'detail': 'shutdown diterima tetapi daemon belum melepas lock; periksa data/daemon.log',
    };
  }

  Future<Map<String, dynamic>> restart() async {
    final result = await stop();
    if (result['stopped'] != true) {
      return {'restarted': false, 'action': 'stop_failed', 'stop': result};
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return start();
  }


  Future<bool> _apiHealthy(String host, int port) {
    final client = TikoRemoteClient(
      baseUrl: 'http://$host:$port',
      token: 'health-check-only',
    );
    return client.health();
  }

  String envToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
