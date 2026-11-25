import 'dart:async';
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
  const _Setting(
    this.label,
    this.path, {
    this.choices = const [],
    this.group = 'Umum',
  });
  final String label;
  final String path;
  final List<String> choices;
  final String group;
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
  String? lastGroup;
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].group != lastGroup) {
      lastGroup = fields[i].group;
      buf.writeln('${palette.dim('│')}${fit('')}${palette.dim('│')}');
      buf.writeln(
        '${palette.dim('│')}${fit(palette.cyan('  ${fields[i].group}'))}${palette.dim('│')}',
      );
    }
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

/// Hermes S9: TUI settings layar penuh gaya Hermes — sidebar kategori di
/// kiri, panel detail di kanan, navigasi tab (←/→/Tab/Shift-Tab), pencarian
/// (`/`), preview perubahan (`p`), dirty-state (`*` per kategori + hitungan
/// di header sebelum disimpan), simpan ber-revisi (`s`), reset (`r`), dan
/// keluar ter-guard saat ada perubahan (`q` ditahan sekali).
///
/// Merender ulang satu region (cursor-up + clear) per event key; bila raw
/// mode tak tersedia, pemanggil ([runSettingsMenu]) jatuh ke menu
/// line-mode lama sehingga perilaku pipe/CI tetap aman.
Future<void> _runSettingsTui({
  required String configPath,
  required String revisionsDir,
  required StringSink out,
  required Stream<List<int>> Function() makeChunks,
  required _Palette palette,
  required bool controlsStdin,
}) async {
  const width = 96;
  const sideW = 26;
  final store = ConfigStore(configPath: configPath, revisionsDir: revisionsDir);
  var cfg = TikoConfig.load(configPath).$1;
  final chunks = StreamIterator(makeChunks());

  var lastLines = 0;
  var categoryIdx = 0;
  var itemIdx = 0;
  var searchMode = false;
  var query = '';
  var previewMode = false;
  var editing = false;
  var editedPath = '';
  var editBuffer = '';
  var quitArmed = false;
  String message = 'Gunakan / cari · p preview · s simpan · Enter ubah';
  final pending = <String, String>{};

  List<_Setting> allFields() => _settingsOf(cfg);

  List<String> categories() {
    final seen = <String>[];
    for (final f in allFields()) {
      if (!seen.contains(f.group)) seen.add(f.group);
    }
    return seen;
  }

  bool categoryDirty(String group) => pending.keys.any(
        (path) =>
            allFields().any((f) => f.path == path && f.group == group),
      );

  List<_Setting> visibleFields() {
    if (query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      return [
        for (final f in allFields())
          if (f.label.toLowerCase().contains(q) ||
              f.path.toLowerCase().contains(q))
            f,
      ];
    }
    final cats = categories();
    if (categoryIdx >= cats.length) categoryIdx = cats.length - 1;
    final group = cats[categoryIdx.clamp(0, cats.length - 1)];
    return [for (final f in allFields()) if (f.group == group) f];
  }

  void renormalizeCursor() {
    final n = visibleFields().length;
    if (itemIdx >= n) itemIdx = n - 1;
    if (itemIdx < 0) itemIdx = 0;
  }

  String frame() {
    final cats = categories();
    final fields = visibleFields();
    if (categoryIdx >= cats.length) categoryIdx = cats.length - 1;
    renormalizeCursor();

    final dirtyCount = pending.length;
    final header = '┌─ Pengaturan Tiko '
        '${dirtyCount == 0 ? '' : palette.yellow('● $dirtyCount perubahan belum disimpan ')}';

    final statusLine = searchMode
        ? 'Cari: $query█  (Enter/Esc selesai)'
        : (previewMode
            ? '${palette.cyan('PREVIEW')} perubahan tertunda (p kembali)'
            : 'Kategori: ${cats[categoryIdx.clamp(0, cats.length - 1)]} '
                '(${categoryIdx + 1}/${cats.length})');

    final sideRows = <String>[
      for (var i = 0; i < cats.length; i++)
        '${i == categoryIdx && !searchMode ? '>' : ' '}'
        ' ${cats[i]}'
        '${categoryDirty(cats[i]) ? ' *' : ''}',
    ];

    final detailRows = <String>[
      if (previewMode)
        for (final e in pending.entries)
          '* ${e.key}: ${_valueOf(cfg, allFields().firstWhere((f) => f.path == e.key, orElse: () => _Setting(e.key, e.key)))} → ${e.value}'
      else
        for (var i = 0; i < fields.length; i++)
          '${i == itemIdx && !searchMode ? '>' : ' '}'
          '${pending.containsKey(fields[i].path) ? '*' : ' '}'
          '${i + 1}. ${fields[i].label}: ${_valueOf(cfg, fields[i])}'
          '${pending.containsKey(fields[i].path) ? ' → ${pending[fields[i].path]}' : ''}',
    ];

    const minRows = 8;
    final rows = [sideRows.length, detailRows.length, minRows]
        .reduce((a, b) => a > b ? a : b);

    String side(int r) =>
        r < sideRows.length ? sideRows[r].padRight(sideW) : ' ' * sideW;
    String detail(int r) =>
        r < detailRows.length ? detailRows[r] : '';

    final lines = <String>[
      '$header┐',
      '├ $statusLine',
      '├ ${'KATEGORI'.padRight(sideW)}│ ${'PENGATURAN / PREVIEW'}',
      for (var r = 0; r < rows; r++)
        '│ ${side(r)}│ ${_clip(detail(r), width - sideW - 3)}',
      '├ ←/→/Tab/Shift-Tab kategori · ↑/↓ pilih · Enter ubah',
      '├ / cari · p preview · s simpan · r reset · q keluar',
      '└ ${_clip(message, width - 4)}┘',
      if (editing)
        '>'
            '${_editingLabel(cfg, editedPath)}'
            ' [$editBuffer█]'
            ' · ${_editingHint(cfg, editedPath)}',
    ];
    return '${lines.join('\n')}\n';
  }

  void render() {
    final rendered = frame();
    final lineCount = rendered.split('\n').length - 1;
    if (lastLines > 0) out.write('\x1B[${lastLines}A\x1B[J');
    out.write(rendered);
    lastLines = lineCount;
  }

  Future<void> savePending() async {
    if (pending.isEmpty) {
      message = palette.dim('(tidak ada perubahan untuk disimpan)');
      return;
    }
    var saved = 0;
    var revision = 0;
    String? failure;
    final savedPaths = <String>[];
    for (final entry in pending.entries) {
      try {
        final result = await store.setPath(entry.key, entry.value);
        final fatal = result.issues.where((i) => i.fatal).toList();
        if (fatal.isNotEmpty) {
          failure = '${entry.key}: ${fatal.join('; ')}';
        } else {
          saved++;
          revision = result.revision;
          savedPaths.add(entry.key);
        }
      } catch (e) {
        failure = '${entry.key}: $e';
      }
    }
    if (saved > 0) {
      cfg = TikoConfig.load(configPath).$1;
      for (final path in List.of(savedPaths)) {
        pending.remove(path);
      }
      message = palette.green(
        'OK: $saved perubahan tersimpan (revision $revision) — config diterapkan untuk perintah baru',
      );
      if (savedPaths.contains('api.port')) {
        message += ' · daemon perlu restart untuk port baru';
      }
      if (savedPaths.contains('security.mode') &&
          cfg.permissionMode == 'auto') {
        message += " · mode 'auto' mengurangi konfirmasi tool";
      }
    }
    if (failure != null) {
      message = palette.yellow('Gagal: $failure — perubahan itu dibatalkan');
    }
  }

  try {
    if (controlsStdin) {
      try {
        stdin.lineMode = false;
        stdin.echoMode = false;
      } on StdinException {
        // Terminal tidak mendukung raw; StreamIterator tetap mencoba.
      }
    }
    render();
    while (await chunks.moveNext()) {
      for (final e in decodeKeys(chunks.current)) {
        if (e.type == KeyType.ctrlC || e.type == KeyType.ctrlD) {
          out.write('\n');
          throw const PromptAborted('settings tui');
        }
        if (editing) {
          switch (e.type) {
            case KeyType.enter:
              final value = editBuffer.trim();
              if (value.isEmpty) {
                editing = false;
                message = palette.dim('(edit dibatalkan — kosong)');
                break;
              }
              final field = allFields().firstWhere(
                (f) => f.path == editedPath,
                orElse: () => _Setting(editedPath, editedPath),
              );
              final problem = _validate(field, value, cfg);
              if (problem != null) {
                message = palette.yellow(problem);
              } else {
                pending[editedPath] = value;
                editing = false;
                quitArmed = false;
                message = palette.dim(
                  "${field.label} → '$value' masuk daftar perubahan (s untuk simpan)",
                );
              }
            case KeyType.backspace:
              if (editBuffer.isNotEmpty) {
                editBuffer = editBuffer.substring(0, editBuffer.length - 1);
              }
            case KeyType.char:
              if (editBuffer.length < 120) editBuffer += e.char;
            case KeyType.ctrlU:
            case KeyType.ctrlW:
              editBuffer = '';
            default:
              break;
          }
          continue;
        }
        final cats = categories();
        final fields = visibleFields();
        switch (e.type) {
          case KeyType.up:
            itemIdx = (itemIdx - 1 + fields.length) % (fields.isEmpty ? 1 : fields.length);
            quitArmed = false;
          case KeyType.down:
            itemIdx = (itemIdx + 1) % (fields.isEmpty ? 1 : fields.length);
            quitArmed = false;
          case KeyType.left:
          case KeyType.tab:
            if (!searchMode) {
              categoryIdx =
                  (categoryIdx - 1 + cats.length) % (cats.isEmpty ? 1 : cats.length);
            } else {
              query = '';
              searchMode = false;
            }
            itemIdx = 0;
            quitArmed = false;
          case KeyType.right:
          case KeyType.shiftTab:
            if (!searchMode) {
              categoryIdx = (categoryIdx + 1) % (cats.isEmpty ? 1 : cats.length);
            } else {
              query = '';
              searchMode = false;
            }
            itemIdx = 0;
            quitArmed = false;
          case KeyType.enter:
            if (searchMode) {
              searchMode = false;
              itemIdx = 0;
            } else if (fields.isEmpty) {
              message = palette.yellow('Tidak ada pengaturan yang cocok.');
            } else {
              editing = true;
              editedPath = fields[itemIdx].path;
              editBuffer = '';
              quitArmed = false;
            }
          case KeyType.backspace:
            if (searchMode && query.isNotEmpty) {
              query = query.substring(0, query.length - 1);
            }
            quitArmed = false;
          case KeyType.char:
            if (searchMode) {
              if (query.length < 80) query += e.char;
              itemIdx = 0;
            } else {
              switch (e.char) {
                case '/':
                  searchMode = true;
                  query = '';
                  quitArmed = false;
                case 'p':
                  previewMode = !previewMode;
                  quitArmed = false;
                case 's':
                  await savePending();
                  quitArmed = false;
                case 'r':
                  pending.clear();
                  quitArmed = false;
                  message = palette.dim('Perubahan tertunda dibuang.');
                case 'k':
                  itemIdx = (itemIdx - 1 + fields.length) %
                      (fields.isEmpty ? 1 : fields.length);
                case 'j':
                  itemIdx = (itemIdx + 1) % (fields.isEmpty ? 1 : fields.length);
                case 'q':
                  if (pending.isNotEmpty && !quitArmed) {
                    quitArmed = true;
                    message = palette.yellow(
                      '${pending.length} perubahan belum disimpan — s simpan, r buang, u lagi untuk keluar tanpa menyimpan',
                    );
                  } else {
                    out.write('\n');
                    lastLines = 0;
                    return;
                  }
                case 'h':
                case '?':
                  message = '↑/↓ pilih · ←/→/Tab kategori · Enter ubah · '
                      '/ cari · p preview · s simpan · r reset · q keluar';
                default:
                  break;
              }
            }
          default:
            break;
        }
      }
      if (lastLines == 0 && quitArmed) {
        lastLines = 0;
      }
      render();
    }
  } finally {
    if (lastLines > 0) out.write('\x1B[${lastLines}A\x1B[J');
    if (controlsStdin) {
      try {
        stdin.lineMode = true;
        stdin.echoMode = true;
      } on StdinException {
        // Terminal sudah ditutup; tidak ada yang perlu dipulihkan.
      }
    }
  }
}

String _editingHint(TikoConfig cfg, String path) {
  final field = _settingsOf(cfg).firstWhere(
    (f) => f.path == path,
    orElse: () => _Setting(path, path),
  );
  return field.choices.isEmpty
      ? 'Enter simpan ke daftar perubahan · Esc batal'
      : 'pilihan: ${field.choices.join(' | ')} · Esc batal';
}

String _editingLabel(TikoConfig cfg, String path) {
  final field = _settingsOf(cfg).firstWhere(
    (f) => f.path == path,
    orElse: () => _Setting(path, path),
  );
  return '${field.label} (${_valueOf(cfg, field)})';
}

String _clip(String text, int width) {
  final probe = text.length + 1;
  return probe > width ? text.substring(0, width - 1) : text.padRight(width);
}

bool _supportsRawStdin() {
  try {
    stdin.lineMode = false;
    stdin.echoMode = false;
    stdin.lineMode = true;
    stdin.echoMode = true;
    return true;
  } on StdinException {
    return false;
  }
}

/// Layar pengaturan interaktif di terminal (Hermes-parity `tiko settings`
/// dan `/settings` pada REPL chat). Secara otomatis memakai TUI layar penuh
/// (Hermes S9) bila raw mode tersedia; bila tidak (pipe/CI/test scripted),
/// merender panel berbingkai dengan nilai config saat ini; perubahan ditulis
/// lewat [ConfigStore.setPath] sehingga selalu tervalidasi TikoConfig dan
/// ber-revisi (rollback via `tiko config rollback`).
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
  final useTui = !forceLineMode &&
      scriptedLines.isEmpty &&
      (inputStream != null || (stdin.hasTerminal && _supportsRawStdin()));
  if (useTui) {
    await _runSettingsTui(
      configPath: configPath,
      revisionsDir: revisionsDir,
      out: sink,
      makeChunks: () => inputStream ?? stdin,
      palette: (color && _colorAllowed())
          ? const _AnsiPalette()
          : const _PlainPalette(),
      controlsStdin: inputStream == null,
    );
    return;
  }
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
      group: 'Provider',
    ),
    _Setting('Model', 'providers.chat.$id.model', group: 'Provider'),
    _Setting('Base URL', 'providers.chat.$id.base_url', group: 'Provider'),
    _Setting(
      'API key (SecretRef env:VAR)',
      'providers.chat.$id.api_key',
      group: 'Provider',
    ),
    const _Setting(
      'Mode keamanan',
      'security.mode',
      choices: ['ask', 'auto', 'deny'],
      group: 'Keamanan',
    ),
    const _Setting('Port API daemon', 'api.port', group: 'Runtime'),
    const _Setting(
      'Vision',
      'features.vision',
      choices: ['true', 'false'],
      group: 'Fitur',
    ),
    const _Setting(
      'Image generation',
      'features.image_generation',
      choices: ['true', 'false'],
      group: 'Fitur',
    ),
    _Setting(
      'Enabled provider "$id"',
      'providers.chat.$id.enabled',
      choices: const ['true', 'false'],
      group: 'Provider lanjutan',
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
