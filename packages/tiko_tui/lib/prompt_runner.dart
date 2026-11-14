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
      return _readLineRaw(label, completions);
    }
    return _readLineScripted(label);
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
