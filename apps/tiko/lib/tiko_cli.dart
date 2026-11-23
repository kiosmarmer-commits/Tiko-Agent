import 'package:tiko_runtime/tiko_runtime.dart';

/// Opsi global CLI tiko hasil [parseTikoArgs].
class TikoArgs {
  const TikoArgs({
    this.configPath = 'config/agent.yaml',
    this.jsonOut = false,
    this.safe = true,
    this.probe = false,
    this.fix = false,
    this.mode = 'auto',
    this.help = false,
    this.rest = const [],
  });

  final String configPath;
  final bool jsonOut;
  final bool safe;
  final bool probe;

  /// F8.4 — `tiko doctor --fix`: provisioning toolchain registry setelah
  /// konfirmasi user.
  final bool fix;
  final String mode;
  final bool help;
  final List<String> rest;
}

/// Parse opsi global CLI tiko. Opsi `--mode`/`--config` tanpa nilai jatuh ke
/// [TikoArgs.rest] (perilaku sama dengan implementasi awal di bin/tiko.dart).
TikoArgs parseTikoArgs(List<String> argv) {
  var configPath = 'config/agent.yaml';
  var jsonOut = false;
  var safe = true;
  var probe = false;
  var fix = false;
  var mode = 'auto';
  var help = false;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--config' && i + 1 < argv.length) {
      configPath = argv[++i];
    } else if (a == '--json') {
      jsonOut = true;
    } else if (a == '--no-safe') {
      safe = false;
    } else if (a == '--probe') {
      probe = true;
    } else if (a == '--fix') {
      fix = true;
    } else if (a == '--mode' && i + 1 < argv.length) {
      mode = argv[++i];
    } else if (a == '-h' || a == '--help') {
      help = true;
    } else {
      rest.add(a);
    }
  }
  return TikoArgs(
    configPath: configPath,
    jsonOut: jsonOut,
    safe: safe,
    probe: probe,
    fix: fix,
    mode: mode,
    help: help,
    rest: rest,
  );
}

/// Hasil parsing argumen `tiko setup`.
class SetupArgs {
  const SetupArgs({
    this.provider = 'mock',
    this.workspace = '.',
    this.force = false,
    this.interactive = false,
    this.smoke = false,
  });

  final String provider;
  final String workspace;
  final bool force;
  final bool interactive;

  /// F1 — jalankan satu turn agentic pasca-setup sebagai bukti akhir:
  /// pertanyaan kalkulasi harus memicu tool `calc` dan menghasilkan angka.
  final bool smoke;
}

/// Parse argumen `tiko setup`; null bila ada opsi tak dikenal (pesan
/// dilaporkan lewat [onUnknown], pemanggil men-set exit code).
SetupArgs? parseSetupArgs(
  List<String> args, {
  void Function(String message)? onUnknown,
}) {
  var provider = 'mock';
  var workspace = '.';
  var force = false;
  var interactive = false;
  var smoke = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--provider' && i + 1 < args.length) {
      provider = args[++i];
    } else if (args[i] == '--workspace' && i + 1 < args.length) {
      workspace = args[++i];
    } else if (args[i] == '--force') {
      force = true;
    } else if (args[i] == '--interactive') {
      interactive = true;
    } else if (args[i] == '--smoke') {
      smoke = true;
    } else {
      onUnknown?.call('Opsi setup tidak dikenal: ${args[i]}');
      return null;
    }
  }
  return SetupArgs(
    provider: provider,
    workspace: workspace,
    force: force,
    interactive: interactive,
    smoke: smoke,
  );
}

/// Baca nilai config untuk path `tiko config get` yang didukung.
String getCfg(TikoConfig c, String path) {
  switch (path) {
    case 'default_provider':
    case 'providers.default':
      return c.defaultProvider;
    case 'workspace':
      return c.workspace;
    case 'api.port':
      return '${c.apiPort}';
    case 'data_dir':
      return c.dataDir;
    default:
      return '(gunakan config show; path $path)';
  }
}

/// Perintah slash yang dilengkapi tab pada REPL chat.
const chatCommands = ['/quit', '/exit', '/doctor', '/status', '/settings'];

/// Completer REPL chat: saring [chatCommands] yang berawalan [token].
List<String> chatCompleter(String prefix, String token) => [
      for (final command in chatCommands)
        if (command.startsWith(token)) command,
    ];
