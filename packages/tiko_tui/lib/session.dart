import 'dart:async';
import 'dart:io';

import 'history_store.dart';
import 'line_editor.dart';

/// Result of handling one REPL input.
class TuiOutcome {
  const TuiOutcome(this.lines, {this.exit = false, this.clear = false});

  final List<String> lines;
  final bool exit;
  final bool clear;
}

typedef TuiHandler = Future<TuiOutcome> Function(String input);
typedef TuiCompleter = List<String> Function(String prefix, String token);

/// Generic interactive terminal session (Hermes-parity TUI): raw-mode line
/// editing with history navigation, Tab autocomplete, multiline input and
/// ANSI colouring. Falls back to a plain line-mode REPL when the terminal
/// does not support raw mode (pipes, CI, restricted environments).
///
/// The [handler] is fully injected, so hosts (tiko chat, simpul tui) only
/// supply command logic; the editing/rendering machinery lives here.
class TuiSession {
  TuiSession({
    required this.handler,
    this.completer,
    this.historyStore,
    List<String>? history,
    this.banner = const [],
    this.prompt = '> ',
    this.continuationPrompt = '  ...> ',
    Stream<List<int>>? inputStream,
    StringSink? out,
    List<String> scriptedLines = const [],
    bool? forceLineMode,
    bool color = true,
  })  : _inputStream = inputStream,
        _out = out ?? stdout,
        _scripted = scriptedLines,
        history = history ?? [],
        _color = color {
    _raw = !(forceLineMode ?? false) &&
        _scripted.isEmpty &&
        (_inputStream != null || (stdin.hasTerminal && _supportsRaw()));
  }

  final TuiHandler handler;
  final TuiCompleter? completer;
  final TuiHistoryStore? historyStore;
  final List<String> banner;
  final String prompt;
  final String continuationPrompt;

  final Stream<List<int>>? _inputStream;
  final StringSink _out;
  final List<String> _scripted;
  int _scriptedIndex = 0;
  StreamIterator<List<int>>? _chunks;

  bool _raw = false;
  bool _color;
  final List<String> history;
  final MultilineBuffer _multiline = MultilineBuffer();

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

  String _paint(String text, String code) =>
      _color ? '\x1B[${code}m$text\x1B[0m' : text;

  Future<void> run() async {
    _color = _color &&
        !Platform.environment.containsKey('NO_COLOR') &&
        (Platform.environment['TERM'] ?? '') != 'dumb';
    final loaded = historyStore?.load() ?? <String>[];
    history.addAll(loaded);
    final editor = LineEditor(history: history, completer: completer);
    for (final line in banner) {
      _out.writeln(_colorize(line));
    }

    try {
      while (true) {
        final line = _raw
            ? await _readLineRaw(editor, _multiline.inBlock
                ? continuationPrompt
                : prompt)
            : _readLineFallback(_multiline.inBlock
                ? continuationPrompt
                : prompt);
        if (line == null) {
          _out.writeln();
          break;
        }
        final submitted = _multiline.submit(line);
        if (submitted == null) continue;
        editor.remember(submitted);
        final outcome = await handler(submitted);
        if (outcome.clear) {
          _out.write('\x1B[2J\x1B[H');
        }
        for (final text in outcome.lines) {
          _out.writeln(_colorize(text));
        }
        if (outcome.exit) break;
      }
    } finally {
      await historyStore?.save(history);
      _disableRawMode();
    }
  }

  String _colorize(String text) {
    if (!_color) return text;
    if (text.startsWith('  [')) return _paint(text, '36');
    if (text.startsWith('  ')) return _paint(text, '90');
    if (text.startsWith('tidak ') || text.startsWith('gagal')) {
      return _paint(text, '33');
    }
    return text;
  }

  void _disableRawMode() {
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } on StdinException {
      // already in line mode or closed
    }
  }

  Future<String?> _readLineRaw(LineEditor editor, String label) async {
    _out.write(label);
    final chunks = _chunks ??= StreamIterator(_inputStream ?? stdin);
    while (await chunks.moveNext()) {
      final bytes = chunks.current;
      for (final event in decodeKeys(bytes)) {
        if (event.type == KeyType.ctrlD && editor.isEmpty) {
          _out.writeln();
          return null;
        }
        if (event.type == KeyType.tab || event.type == KeyType.shiftTab) {
          final candidates = editor.complete();
          if (candidates.length > 1) {
            _out.writeln();
            _out.writeln(candidates.join('  '));
          }
          _rerender(editor, label);
          continue;
        }
        final submit = editor.handle(event);
        if (submit) {
          _out.writeln();
          final line = editor.buffer;
          editor.buffer = '';
          editor.cursor = 0;
          return line;
        }
        _rerender(editor, label);
      }
    }
    _out.writeln();
    return null;
  }

  void _rerender(LineEditor editor, String label) {
    final cursorCol = label.length + editor.cursor;
    _out.write(
      '\x1B[2K\r$label${editor.buffer}\x1B[1G\x1B[${cursorCol + 1}C',
    );
  }

  String? _readLineFallback(String label) {
    _out.write(label);
    if (_scriptedIndex < _scripted.length) {
      final line = _scripted[_scriptedIndex++];
      _out.writeln(line);
      return line;
    }
    return stdin.readLineSync();
  }
}
