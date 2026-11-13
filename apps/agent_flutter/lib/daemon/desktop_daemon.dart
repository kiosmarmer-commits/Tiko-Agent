import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of a self-contained desktop daemon launch.
class DaemonConnection {
  const DaemonConnection({
    required this.baseUrl,
    required this.token,
    required this.mode,
    this.pid,
    this.logPath,
    this.home,
  });

  final String baseUrl;
  final String token;

  /// `reuse` (daemon already healthy), `started` (spawned), or
  /// `unavailable` (desktop bootstrap failed; caller falls back).
  final String mode;
  final int? pid;
  final String? logPath;
  final String? home;
}

/// Self-contained desktop bootstrap (Hermes-parity): the Flutter desktop app
/// spawns its own agentd daemon from a bundled compiled binary, so the user
/// never has to run `agentd --api` manually.
///
/// Resolution order:
/// 1. Health check at the target base URL → reuse the running daemon.
/// 2. Binary lookup: `AGENTD_BIN` (dart-define) → sibling of the executable
///    (`agentd` / `agentd.exe`) → macOS `Contents/Resources/agentd`.
/// 3. Spawn with a per-user home (`TIKO_HOME` or `~/.tiko-agent`),
///    bootstrapping a minimal config when missing, then wait for
///    `/health` and read the token from `data/api.token`.
///
/// Like Hermes, the daemon is NOT stopped when the app quits: it outlives the
/// window so scheduled jobs and messaging gateways keep running. [stop]
/// exists for explicit control from Settings and only ever asks the
/// authenticated daemon API to shut itself down (never signals a raw PID).
class DesktopDaemon {
  DesktopDaemon._();

  /// Most recent successful bootstrap, for display in the app's Settings.
  static DaemonConnection? lastConnection;

  /// Default API port, matching agentd's config default.
  static const defaultPort = 8787;

  /// Minimal bootstrap config so a fresh install boots immediately; the user
  /// can point providers at real credentials later by editing this file.
  static const bootstrapConfig = '''
# Tiko Agent — konfigurasi minimal (di-generate desktop app).
# Ganti provider di bawah dengan provider sungguhan (lihat docs konfigurasi).
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
''';

  /// True when running on a desktop platform where self-contained launch
  /// applies.
  static bool get isDesktopPlatform =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Per-user agent home: `TIKO_HOME` env override, else `~/.tiko-agent`.
  static String agentHome({String? homeOverride}) {
    final env = Platform.environment;
    final explicit = homeOverride ?? env['TIKO_HOME'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final home = Platform.isWindows
        ? (env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path)
        : (env['HOME'] ?? Directory.current.path);
    return p.join(home, '.tiko-agent');
  }

  /// Locates the bundled agentd binary, or null in dev mode.
  static String? findAgentdBinary({String? binaryOverride}) {
    final candidates = <String>[];
    if (binaryOverride != null && binaryOverride.isNotEmpty) {
      candidates.add(binaryOverride);
    }
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final exeName = Platform.isWindows ? 'agentd.exe' : 'agentd';
      candidates.add(p.join(exeDir, exeName));
      if (Platform.isMacOS) {
        // Flutter macOS app: executable lives in Contents/MacOS/, resources
        // in Contents/Resources/.
        candidates.add(p.join(exeDir, '..', 'Resources', 'agentd'));
      }
    } on UnsupportedError {
      // resolvedExecutable unsupported in some embedding contexts.
    }
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Writes the bootstrap config when no config exists yet. Returns the
  /// config path.
  static String ensureConfig(String home) {
    final configDir = Directory(p.join(home, 'config'));
    if (!configDir.existsSync()) {
      configDir.createSync(recursive: true);
    }
    final configPath = p.join(configDir.path, 'agent.yaml');
    if (!File(configPath).existsSync()) {
      File(configPath).writeAsStringSync(bootstrapConfig);
    }
    return configPath;
  }

  /// Reads the daemon API token from `<home>/data/api.token` (plain text,
  /// owner-only permissions set by the daemon).
  static String? readToken(String home) {
    try {
      final f = File(p.join(home, 'data', 'api.token'));
      if (!f.existsSync()) return null;
      final value = f.readAsStringSync().trim();
      return value.length >= 32 ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Ensures a daemon is reachable, spawning a bundled binary when needed.
  /// Returns null when self-contained bootstrap does not apply (non-desktop)
  /// or failed — callers fall back to the dart-define connection settings.
  static Future<DaemonConnection?> ensure({
    String? homeOverride,
    String? binaryOverride,
    String? baseOverride,
    int? portOverride,
  }) async {
    if (!isDesktopPlatform) return null;
    final home = agentHome(homeOverride: homeOverride);
    final port = portOverride ??
        (int.tryParse(Platform.environment['API_PORT'] ?? '') ?? defaultPort);
    final base = baseOverride ?? 'http://127.0.0.1:$port';

    // 1. Reuse a healthy daemon (ours or a previously spawned one).
    if (await health(base)) {
      final token = readToken(home);
      if (token != null && token.isNotEmpty) {
        return lastConnection = DaemonConnection(
          baseUrl: base,
          token: token,
          mode: 'reuse',
          home: home,
        );
      }
    }

    // 2. Spawn the bundled daemon binary (self-contained path).
    final binary = findAgentdBinary(binaryOverride: binaryOverride);
    if (binary == null) return null;
    final configPath = ensureConfig(home);
    final dataDir = p.join(home, 'data');
    final logDir = Directory(dataDir);
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    final logPath = p.join(dataDir, 'daemon.log');
    // NOTE: no API_TOKEN is injected — agentd generates a secure random
    // token itself and persists it to data/api.token (owner-only perms),
    // which we read back below.
    final env = Map<String, String>.from(Platform.environment)
      ..remove('API_TOKEN')
      ..['API_PORT'] = '$port'
      ..['TIKO_CONFIG'] = configPath
      ..['AGENT_UI'] = '1';

    Process? proc;
    try {
      proc = await Process.start(
        binary,
        const ['--api'],
        environment: env,
        mode: ProcessStartMode.detachedWithStdio,
        workingDirectory: home,
      );
    } catch (_) {
      return null;
    }
    final log = File(logPath).openWrite(mode: FileMode.append);
    proc.stdout.listen(log.add, onDone: log.close);
    proc.stderr.listen(log.add, onDone: log.close);

    // 3. Wait for the HTTP health endpoint (bounded).
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await health(base)) {
        final token = readToken(home);
        if (token != null && token.isNotEmpty) {
          return lastConnection = DaemonConnection(
            baseUrl: base,
            token: token,
            mode: 'started',
            pid: proc.pid,
            logPath: logPath,
            home: home,
          );
        }
      }
    }
    return null;
  }

  /// Health probe against the daemon API.
  static Future<bool> health(String base) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client
          .getUrl(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Asks the authenticated daemon API to shut itself down. Never signals a
  /// raw PID: PIDs can be reused between lock read and signal.
  static Future<bool> stop({required String baseUrl, required String token}) async {
    final client = HttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse('$baseUrl/v1/shutdown'))
          .timeout(const Duration(seconds: 8));
      req.headers.set('Authorization', 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) return false;
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

}
