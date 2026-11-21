import 'dart:async';
import 'dart:io';

import 'history_store.dart';
import 'line_editor.dart';

/// Thrown when the user aborts an interactive prompt (Ctrl+C / EOF).
class PromptAborted implements Exception {
  const PromptAborted(this.label);
  final String label;
  @override
  String toString() => 'prompt dibatalkan: $label';
}

/// Interactive single-line prompts for wizards (Hermes-parity `tiko setup`):
/// per-character editing, history navigation, Tab autocomplete and safe
/// fallback to plain line mode when raw mode is unavailable (pipes, CI).
///
/// Testable: inject [scriptedLines] (forces line mode) or [inputStream]
/// (raw bytes) instead of the real stdin.
class PromptRunner {
  PromptRunner({
    Stream<List<int>>? inputStream,
    StringSink? out,
    List<String> scriptedLines = const [],
    List<String>? history,
    this.historyStore,
    bool? forceLineMode,
  })  : _inputStream = inputStream,
        _out = out ?? stdout,
        _scripted = scriptedLines,
        history = history ?? [] {
    _raw = !(forceLineMode ?? false) &&
        _scripted.isEmpty &&
        (inputStream != null || (stdin.hasTerminal && _supportsRaw()));
  }

  final Stream<List<int>>? _inputStream;
  final StringSink _out;
  final List<String> _scripted;
  final TuiHistoryStore? historyStore;
  final List<String> history;

  bool _raw = false;
  int _scriptedIndex = 0;
  StreamIterator<List<int>>? _chunks;

  static bool _supportsRaw() {
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

  /// Reads one edited line. [completions] are offered on Tab.
  Future<String> readLine(
    String label, {
    List<String> completions = const [],
  }) async {
    if (_raw) {
      await _enterRaw();
      try {
        return await _readLineRaw(label, completions);
      } finally {
        _exitRaw();
      }
    }
    return _readLineScripted(label);
  }

  /// Menu pilihan gaya TUI (Hermes-parity): panah atas/bawah untuk memindah
  /// kursor, Enter untuk memilih, atau tekan angka 1..9 untuk lompat langsung.
  /// Kembali nilai opsi yang dipilih. Bila raw mode tidak tersedia (pipe/CI/test
  /// scripted), turun ke menu bernomor yang dibaca baris-demi-baris.
  Future<String> select(
    String label,
    List<String> options, {
    String? def,
  }) async {
    if (options.isEmpty) throw ArgumentError('setidaknya satu opsi diperlukan');
    if (!_raw) {
      // Mode line/scripted: menu bernomor sederhana.
      for (var i = 0; i < options.length; i++) {
        final mark = options[i] == def ? ' (default)' : '';
        _out.writeln('  ${i + 1}. ${options[i]}$mark');
      }
      final parsed = RegExp(r'^\s*(\d+)\s*$');
      while (true) {
        final line = _readLineScripted('$label [1-${options.length}]: ');
        if (line.trim().isEmpty && def != null && options.contains(def)) {
          return def;
        }
        final m = parsed.firstMatch(line);
        final n = m == null ? 0 : int.parse(m.group(1)!);
        if (n >= 1 && n <= options.length) return options[n - 1];
        _out.writeln('  Pilih angka 1-${options.length} (kosong = default).');
      }
    }
    await _enterRaw();
    try {
      return await _selectRaw(label, options, def);
    } finally {
      _exitRaw();
    }
  }

  Future<String> _selectRaw(
    String label,
    List<String> options,
    String? def,
  ) async {
    var cursor = options.indexOf(def ?? '');
    if (cursor < 0) cursor = 0;
    var painted = false;
    void render() {
      final buf = StringBuffer();
      if (painted) buf.write('\x1B[${options.length}A');
      buf.write('\x1B[J');
      buf.writeln(label);
      for (var i = 0; i < options.length; i++) {
        final marker = i == cursor ? '>' : ' ';
        buf.write(i == cursor ? '\x1B[7m' : '');
        buf.writeln(' $marker ${i + 1}. ${options[i]}\x1B[0m');
      }
      _out.write(buf.toString());
      painted = true;
    }

    render();
    final chunks = _chunks ??= StreamIterator(_inputStream ?? stdin);
    while (await chunks.moveNext()) {
      for (final event in decodeKeys(chunks.current)) {
        switch (event.type) {
          case KeyType.up:
            cursor = (cursor - 1 + options.length) % options.length;
            render();
          case KeyType.down:
            cursor = (cursor + 1) % options.length;
            render();
          case KeyType.enter:
            _out.writeln();
            return options[cursor];
          case KeyType.ctrlC:
          case KeyType.ctrlD:
            _out.writeln();
            throw PromptAborted(label);
          case KeyType.tab:
            break;
          case KeyType.char:
            final digits = int.tryParse(event.char);
            if (digits != null && digits >= 1 && digits <= options.length) {
              _out.writeln();
              return options[digits - 1];
            }
            if (event.char == 'k') {
              cursor = (cursor - 1 + options.length) % options.length;
              render();
            } else if (event.char == 'j') {
              cursor = (cursor + 1) % options.length;
              render();
            }
          default:
            break;
        }
      }
    }
    _out.writeln();
    throw PromptAborted(label);
  }

  Future<void> _enterRaw() async {
    if (_inputStream != null) return;
    try {
      stdin.lineMode = false;
      stdin.echoMode = false;
    } on StdinException {
      _raw = false;
    }
  }

  void _exitRaw() {
    if (_inputStream != null) return;
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } on StdinException {
      // Terminal sudah ditutup; tidak ada yang perlu dipulihkan.
    }
  }

  /// Prompt with default/required semantics used by the setup wizard.
  Future<String> prompt(
    String label, {
    String? def,
    bool required = false,
    List<String> completions = const [],
  }) async {
    while (true) {
      final suffix = (def != null && def.isNotEmpty) ? ' [$def]' : '';
      final line = (await readLine('$label$suffix: ', completions: completions))
          .trim();
      if (line.isEmpty && def != null && def.isNotEmpty) return def;
      if (line.isNotEmpty) return line;
      if (!required) return '';
      _out.writeln('  Wajib diisi.');
    }
  }

  /// y/N confirmation prompt.
  Future<bool> confirm(String label) async {
    final line = (await readLine('$label [y/N]: ')).trim().toLowerCase();
    return line == 'y' || line == 'ya' || line == 'yes';
  }

  Future<void> saveHistory() => historyStore?.save(history) ?? Future.value();

  Future<String> _readLineRaw(String label, List<String> completions) async {
    final editor = LineEditor(
      history: history,
      completer: (prefix, token) => completions
          .where((c) => c.startsWith(token) && c != token)
          .toList(),
    );
    _out.write(label);
    final chunks = _chunks ??= StreamIterator(_inputStream ?? stdin);
    while (await chunks.moveNext()) {
      final bytes = chunks.current;
      for (final event in decodeKeys(bytes)) {
        if (event.type == KeyType.ctrlC) {
          _out.writeln();
          throw PromptAborted(label);
        }
        if (event.type == KeyType.ctrlD && editor.isEmpty) {
          _out.writeln();
          throw PromptAborted(label);
        }
        if (event.type == KeyType.tab || event.type == KeyType.shiftTab) {
          final candidates = editor.complete();
          if (candidates.length > 1) {
            _out.writeln();
            _out.writeln(candidates.join('  '));
          }
          _rerender(label, editor);
          continue;
        }
        final submit = editor.handle(event);
        if (submit) {
          _out.writeln();
          final line = editor.buffer;
          editor.remember(line);
          return line;
        }
        _rerender(label, editor);
      }
    }
    _out.writeln();
    throw PromptAborted(label);
  }

  void _rerender(String label, LineEditor editor) {
    final cursorCol = label.length + editor.cursor;
    _out.write(
      '\x1B[2K\r$label${editor.buffer}\x1B[1G\x1B[${cursorCol + 1}C',
    );
  }

  String _readLineScripted(String label) {
    _out.write(label);
    if (_scriptedIndex < _scripted.length) {
      final line = _scripted[_scriptedIndex++];
      _out.writeln(line);
      if (line.trim().isNotEmpty) history.add(line.trim());
      return line;
    }
    if (_scripted.isNotEmpty) {
      throw PromptAborted(label);
    }
    final line = stdin.readLineSync();
    if (line == null) {
      _out.writeln();
      throw PromptAborted(label);
    }
    if (line.trim().isNotEmpty) history.add(line.trim());
    return line;
  }
}
