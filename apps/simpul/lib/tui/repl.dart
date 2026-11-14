import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'line_editor.dart';
import 'commands.dart';

/// Interactive terminal session (Hermes-parity TUI): raw-mode line editing
/// with history navigation, tab autocomplete, multiline input and ANSI
/// colouring. Falls back to a plain line-mode REPL when the terminal does
/// not support raw mode (pipes, restricted environments, legacy Windows).
class TuiSession {
  TuiSession({required this.commands, this.historyStore});

  final TuiCommands commands;
  final TuiHistoryStore? historyStore;

  static const prompt = 'simpul> ';
  static const contPrompt = '  ...> ';

  bool _color = true;

  String _paint(String text, String code) =>
      _color ? '\x1B[${code}m$text\x1B[0m' : text;

  Future<void> run() async {
    final rawSupported = _enableRawMode();
    _color = _detectColor();
    final history = historyStore?.load() ?? <String>[];
    final editor = LineEditor(
      history: history,
      completer: commands.complete,
    );
    final multiline = MultilineBuffer();
    final out = stdout;
    out.writeln(_paint('Simpul TUI — vault: ${commands.vault}', '1;36'));
    out.writeln(_paint('/help untuk bantuan, /quit untuk keluar.', '90'));

    try {
      while (true) {
        final line = rawSupported
            ? await _readLineRaw(editor, multiline.inBlock ? contPrompt : prompt, out)
            : _readLineFallback(multiline.inBlock ? contPrompt : prompt);
        if (line == null) {
          out.writeln();
          break;
        }
        final submitted = multiline.submit(line);
        if (submitted == null) {
          continue;
        }
        editor.remember(submitted);
        final outcome = await commands.run(submitted);
        if (outcome.clear) {
          out.write('\x1B[2J\x1B[H');
        }
        for (final text in outcome.lines) {
          out.writeln(_colorize(text));
        }
        if (outcome.exit) break;
      }
    } finally {
      _disableRawMode();
      await historyStore?.save(commands.history);
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

  bool _detectColor() {
    if (Platform.environment.containsKey('NO_COLOR')) return false;
    final term = Platform.environment['TERM'] ?? '';
    if (term == 'dumb') return false;
    return stdout.hasTerminal;
  }

  bool _enableRawMode() {
    if (!stdin.hasTerminal) return false;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      return true;
    } on StdinException {
      return false;
    }
  }

  void _disableRawMode() {
    try {
      stdin.lineMode = true;
      stdin.echoMode = true;
    } on StdinException {
      // already in line mode or closed
    }
  }

  /// Raw-mode read: feeds decoded key events into [editor], re-renders the
  /// line in place, returns the submitted line (without newline).
  Future<String?> _readLineRaw(
    LineEditor editor,
    String prompt,
    Stdout out,
  ) async {
    out.write(prompt);
    while (true) {
      final bytes = await stdin.first;
      for (final event in decodeKeys(bytes)) {
        if (event.type == KeyType.ctrlD && editor.isEmpty) {
          out.writeln();
          return null;
        }
        if (event.type == KeyType.tab || event.type == KeyType.shiftTab) {
          final candidates = editor.complete();
          if (candidates.length > 1) {
            out.writeln();
            out.writeln(candidates.join('  '));
          }
          _rerender(out, prompt, editor);
          continue;
        }
        final submit = editor.handle(event);
        if (submit) {
          out.writeln();
          final line = editor.buffer;
          editor.buffer = '';
          editor.cursor = 0;
          return line;
        }
        _rerender(out, prompt, editor);
      }
    }
  }

  void _rerender(Stdout out, String prompt, LineEditor editor) {
    final cursorCol = prompt.length + editor.cursor;
    final seq = StringBuffer()
      ..write('\x1B[2K\r')
      ..write(prompt)
      ..write(editor.buffer)
      ..write('\x1B[1G\x1B[${cursorCol + 1}C');
    out.write(seq.toString());
  }

  String? _readLineFallback(String prompt) {
    stdout.write(prompt);
    return stdin.readLineSync();
  }
}

/// Entry point used by `simpul tui <vault>`.
Future<void> runTui(String vault) async {
  final historyPath = Platform.environment['SIMPUL_HISTORY'] ??
      p.join(vault, '.simpul', 'tui-history.txt');
  final session = TuiSession(
    commands: TuiCommands(vault: vault),
    historyStore: TuiHistoryStore(historyPath),
  );
  await session.run();
}
