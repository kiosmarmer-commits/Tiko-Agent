import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:tiko_tui/tiko_tui.dart';

/// Antarmuka palet ANSI untuk panel settings (versi polos saat warna nonaktif).
abstract final class _Palette {
  String cyan(String text);
  String yellow(String text);
  String green(String text);
  String dim(String text);
  String bold(String text);
}

final class _AnsiPalette implements _Palette {
  const _AnsiPalette();
  @override
  String cyan(String text) => _paint(text, '36');
  @override
  String yellow(String text) => _paint(text, '33');
  @override
  String green(String text) => _paint(text, '32');
  @override
  String dim(String text) => _paint(text, '90');
  @override
  String bold(String text) => _paint(text, '1');
}

final class _PlainPalette implements _Palette {
  const _PlainPalette();
  @override
  String cyan(String text) => text;
  @override
  String yellow(String text) => text;
  @override
  String green(String text) => text;
  @override
  String dim(String text) => text;
  @override
  String bold(String text) => text;
}

String _paint(String text, String code) => '\x1B[${code}m$text\x1B[0m';

bool _colorAllowed() => TuiTheme.terminalColorAllowed();

/// Satu field yang dapat diubah di layar settings.
class _Setting {
  const _Setting(this.label, this.path, {this.choices = const []});
  final String label;
  final String path;
  final List<String> choices;
}

String _valueOf(TikoConfig cfg, _Setting s) {
  final prov = cfg.providers[cfg.defaultProvider];
  return switch (s.path) {
    'providers.default_chat' => '${cfg.defaultProvider} (${prov?.type ?? '-'})',
    'security.mode' => cfg.permissionMode,
    'api.port' => '${cfg.apiPort}',
    'features.vision' => '${cfg.enableVision}',
    'features.image_generation' => '${cfg.enableImageGeneration}',
    _ => switch (s.path.split('.').last) {
      'model' => prov?.model ?? '(default)',
      'base_url' => prov?.baseUrl ?? '(default)',
      'api_key' => prov?.apiKeyRef ?? '(belum diset)',
      'enabled' => '${prov?.enabled ?? true}',
      _ => '-',
    },
  };
}

String _panel(
  _Palette palette,
  TikoConfig cfg,
  List<_Setting> fields,
  String configPath,
) {
  const width = 78;
  String fit(String text) {
    final probe = ' $text ';
    return probe.length > width - 2
        ? probe.substring(0, width - 2)
        : probe.padRight(width - 2);
  }

  final buf = StringBuffer();
  buf.writeln(
    palette.dim('┌${'─ Pengaturan Tiko '.padRight(width - 2, '─')}┐'),
  );
  for (var i = 0; i < fields.length; i++) {
    buf.writeln(
      '${palette.dim('│')}${fit('${i + 1}  ${fields[i].label}: '
      '${_valueOf(cfg, fields[i])}')}${palette.dim('│')}',
    );
  }
  buf.writeln('${palette.dim('│')}${fit('')}${palette.dim('│')}');
  buf.writeln(
    '${palette.dim('│')}${fit('Perubahan tervalidasi & ber-revisi — rollback: '
    'tiko config rollback <rev>')}${palette.dim('│')}',
  );
  buf.writeln(
    '${palette.dim('│')}${fit('config: $configPath')}${palette.dim('│')}',
  );
  buf.writeln(palette.dim('└${'─' * (width - 2)}┘'));
  return buf.toString();
}

/// Layar pengaturan interaktif di terminal (Hermes-parity `tiko settings`
/// dan `/settings` pada REPL chat). Merender panel berbingkai dengan nilai
/// config saat ini; perubahan ditulis lewat [ConfigStore.setPath] sehingga
/// selalu tervalidasi TikoConfig dan ber-revisi (rollback via
/// `tiko config rollback`).
///
/// Testable: injeksi [out], [inputStream], atau [scriptedLines] (memaksa
/// line mode) seperti [PromptRunner].
Future<void> runSettingsMenu({
  required String configPath,
  required String revisionsDir,
  StringSink? out,
  Stream<List<int>>? inputStream,
  List<String> scriptedLines = const [],
  bool forceLineMode = false,
  bool color = true,
}) async {
  final sink = out ?? stdout;
  final palette = (color && _colorAllowed())
      ? const _AnsiPalette()
      : const _PlainPalette();
  final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
  var cfg = TikoConfig.load(configPath).$1;
  final prompts = PromptRunner(
    inputStream: inputStream,
    out: sink,
    scriptedLines: scriptedLines,
    forceLineMode: forceLineMode,
  );

  while (true) {
    final fields = _settingsOf(cfg);
    sink.writeln();
    sink.writeln(_panel(palette, cfg, fields, p.absolute(configPath)));
    final choices = [
      for (final field in fields) '${field.label}  ·  ${_valueOf(cfg, field)}',
    ];
    choices.add('Keluar dari settings');
    String selected;
    try {
      selected = await prompts.select(
        'Pilih pengaturan (↑/↓, Enter, angka; q keluar):',
        choices,
        quitValue: choices.last,
      );
    } on PromptAborted {
      rethrow;
    }
    if (selected == choices.last) break;
    final idx = choices.indexOf(selected);
    if (idx < 0 || idx >= fields.length) continue;
    final setting = fields[idx];
    String value;
    try {
      value = (await prompts.prompt(
        'nilai ${setting.label}',
        completions: setting.choices,
      )).trim();
    } on PromptAborted {
      rethrow;
    }
    if (value.isEmpty) {
      sink.writeln('  (batal — tidak ada perubahan)');
      continue;
    }
    final problem = _validate(setting, value, cfg);
    if (problem != null) {
      sink.writeln(palette.yellow('  $problem'));
      continue;
    }
    final result = await store.setPath(setting.path, value);
    final fatal = result.issues.where((i) => i.fatal).toList();
    if (fatal.isNotEmpty) {
      sink.writeln(palette.yellow('  Perubahan tidak disimpan:'));
      for (final issue in fatal) {
        sink.writeln('  - $issue');
      }
      continue;
    }
    cfg = TikoConfig.load(configPath).$1;
    sink.writeln(
      palette.green(
        '  OK ${setting.path} = $value (revision ${result.revision})',
      ),
    );
    if (setting.path == 'api.port') {
      sink.writeln(
        '  Catatan: daemon aktif tetap memakai port lama sampai '
        '`tiko daemon restart`.',
      );
    } else if (setting.path == 'security.mode' && value == 'auto') {
      sink.writeln(
        palette.yellow(
          "  Peringatan: mode 'auto' mengurangi konfirmasi tool — pakai "
          "'ask' kecuali sadar risikonya.",
        ),
      );
    }
  }
}

List<_Setting> _settingsOf(TikoConfig c) {
  final id = c.defaultProvider;
  return [
    _Setting(
      'Provider utama',
      'providers.default_chat',
      choices: c.providers.keys.toList(),
    ),
    _Setting('Model', 'providers.chat.$id.model'),
    _Setting('Base URL', 'providers.chat.$id.base_url'),
    _Setting('API key (SecretRef env:VAR)', 'providers.chat.$id.api_key'),
    const _Setting(
      'Mode keamanan',
      'security.mode',
      choices: ['ask', 'auto', 'deny'],
    ),
    const _Setting('Port API daemon', 'api.port'),
    const _Setting('Vision', 'features.vision', choices: ['true', 'false']),
    const _Setting(
      'Image generation',
      'features.image_generation',
      choices: ['true', 'false'],
    ),
    _Setting(
      'Enabled provider "$id"',
      'providers.chat.$id.enabled',
      choices: const ['true', 'false'],
    ),
  ];
}

/// Validasi ringan sebelum tulis; validasi penuh tetap dilakukan
/// [ConfigStore] via TikoConfig.load pada file sementara.
String? _validate(_Setting setting, String value, TikoConfig cfg) {
  switch (setting.path) {
    case 'providers.default_chat':
      if (!cfg.providers.containsKey(value)) {
        return "provider '$value' tidak ada; tambahkan via "
            '`tiko setup --interactive` atau config set '
            'providers.chat.$value.type';
      }
      if (cfg.providers[value]?.enabled == false) {
        return "provider '$value' disabled — set "
            'providers.chat.$value.enabled terlebih dahulu';
      }
      return null;
    case 'security.mode':
      if (!const {'ask', 'auto', 'deny'}.contains(value)) {
        return 'harus ask | auto | deny';
      }
      return null;
    case 'api.port':
      final port = int.tryParse(value);
      if (port == null || port < 1 || port > 65535) {
        return 'harus integer 1 sampai 65535';
      }
      return null;
    case 'features.vision':
    case 'features.image_generation':
      if (value != 'true' && value != 'false') return 'harus true atau false';
      return null;
    default:
      if (setting.path.endsWith('.api_key') &&
          !RegExp(r'^env:[A-Z_][A-Z0-9_]{0,127}$').hasMatch(value)) {
        return "gunakan SecretRef 'env:NAMA_VAR'; secret mentah dilarang "
            '(nilai rahasianya disimpan di gateway.env via '
            '`tiko setup --interactive`)';
      }
      if (setting.path.endsWith('.enabled') &&
          value != 'true' &&
          value != 'false') {
        return 'harus true atau false';
      }
      return null;
  }
}
