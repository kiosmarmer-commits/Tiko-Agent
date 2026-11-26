import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'history_store.dart';
import 'line_editor.dart';
import 'theme.dart';

/// Result of handling one REPL input.
class TuiOutcome {
  const TuiOutcome(this.lines, {this.exit = false, this.clear = false});

  final List<String> lines;
  final bool exit;
  final bool clear;
}

/// Live progress handle (TUI-P3): host memperbarui label status selama turn
/// async berjalan (mis. "tool shell_exec…") dan session merender spinner
/// di posisi prompt. [cancelled] dipanggil session saat pengguna menekan
/// Ctrl-C selama turn berjalan; host memetakan ini ke pembatalan runtime.
class TuiProgress {
  TuiProgress({
    required void Function(String label) onUpdate,
    void Function()? onCancel,
  })  : _onUpdate = onUpdate,
        _onCancel = onCancel;

  final void Function(String label) _onUpdate;
  final void Function()? _onCancel;
  bool _cancelNotified = false;

  /// Label status ter aktif (default "Thinking…", diubah host).
  String label = 'Thinking…';

  /// Perbarui label status live; dipanggil host dari callback runtime.
  void status(String value) {
    label = value;
    _onUpdate(value);
  }

  /// Sinyal cancel dari Ctrl-C (idempoten).
  void cancelled() {
    if (_cancelNotified) return;
    _cancelNotified = true;
    _onCancel?.call();
  }

  bool get cancelNotified => _cancelNotified;
}

/// Handler dengan progres opsional: closure satu argumen lama tetap valid
/// (positional parameter kedua opsional).
typedef TuiHandler = Future<TuiOutcome> Function(String input);
typedef TuiCompleter = List<String> Function(String prefix, String token);

/// Antrean input mentah yang dapat ditunggu bergantian oleh editor baris
/// (saat idle) dan loop progres (saat turn berjalan) tanpa kehilangan byte:
/// event yang tiba saat tidak ada pembaca tetap tersimpan, dan pembaca baru
/// melanjutkan completer yang tertunda (bukan membuat baru).
class _InputBuffer {
  _InputBuffer(Stream<List<int>> source) {
    _sub = source.listen(
      (chunk) {
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          _ready = null;
          ready.complete(chunk);
        } else {
          _buffered.addLast(chunk);
        }
      },
      onDone: () {
        _done = true;
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          _ready = null;
          ready.complete(null);
        }
      },
    );
  }

  late final StreamSubscription<List<int>> _sub;
  final Queue<List<int>> _buffered = Queue();
  Completer<List<int>?>? _ready;
  bool _done = false;

  /// Satu pembaca aktif: mengembalikan chunk berikutnya atau null saat EOF.
  /// Dipanggil ulang setelah `Future.any` kalah race oleh aman — completer
  /// yang sama dipakai ulang, tidak ada StateError dan tidak ada byte hilang.
  Future<List<int>?> next() {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeFirst());
    if (_done) return Future.value(null);
    return (_ready ??= Completer<List<int>?>()).future;
  }

  void dispose() {
    _sub.cancel();
  }
}

/// Generic interactive terminal session (Hermes-parity TUI): raw-mode line
/// editing with history navigation, Tab autocomplete, multiline input and
/// ANSI colouring. Falls back to a plain line-mode REPL when the terminal
/// does not support raw mode (pipes, CI, restricted environments).
///
/// The [handler] is fully injected, so hosts (tiko chat, simpul tui) only
/// supply command logic; the editing/rendering machinery lives here.
///
/// TUI-P3: selama handler berjalan di raw mode, session menampilkan
/// spinner/status live ([TuiProgress]) dan mengawasi input — Ctrl-C
/// memanggil [onCancelKey] untuk kooperatif membatalkan turn.
class TuiSession {
  TuiSession({
    required this.handler,
    this.completer,
    this.historyStore,
    this.onCancelKey,
    this.onTurnStart,
    List<String>? history,
    this.banner = const [],
    this.prompt = '> ',
    this.continuationPrompt = '  ...> ',
    Stream<List<int>>? inputStream,
    StringSink? out,
    List<String> scriptedLines = const [],
    bool? forceLineMode,
    bool color = true,
  }) : _inputStream = inputStream,
       _out = out ?? stdout,
       _scripted = scriptedLines,
       history = history ?? [],
       _color = color {
    _raw =
        !(forceLineMode ?? false) &&
        _scripted.isEmpty &&
        (_inputStream != null || (stdin.hasTerminal && _supportsRaw()));
  }

  final TuiHandler handler;
  final TuiCompleter? completer;
  final TuiHistoryStore? historyStore;

  /// Dipanggil saat Ctrl-C ditekan di tengah turn (raw mode). Host
  /// memetakan ini ke pembatalan turn runtime (mis. `rt.cancelTurn`).
  final void Function()? onCancelKey;

  /// TUI-P3: dipanggil tepat sebelum handler input dieksekusi (raw mode)
  /// dengan handle progres turn tsb; host memakai [TuiProgress.status]
  /// untuk status live dan menyimpan referensi untuk turn ini.
  final void Function(TuiProgress progress)? onTurnStart;

  final List<String> banner;
  final String prompt;
  final String continuationPrompt;

  final Stream<List<int>>? _inputStream;
  final StringSink _out;
  final List<String> _scripted;
  int _scriptedIndex = 0;
  _InputBuffer? _input;

  bool _raw = false;
  bool _color;

  /// E1 — interupsi-dan-redirect: byte yang diketik pengguna selama turn
  /// (selain Ctrl-C/Esc) ditampung dan di-prefill ke editor prompt
  /// berikutnya, sehingga ketikan saat turn berjalan tidak hilang.
  String _pendingRedirect = '';

  final List<String> history;
  final MultilineBuffer _multiline = MultilineBuffer();

  _InputBuffer get _inputBuffer =>
      _input ??= _InputBuffer(_inputStream ?? stdin);

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
    _color = _color && TuiTheme.terminalColorAllowed();
    final loaded = historyStore?.load() ?? <String>[];
    history.addAll(loaded);
    final editor = LineEditor(history: history, completer: completer);
    for (final line in banner) {
      _out.writeln(_colorize(line));
    }

    try {
      while (true) {
        if (_raw && _pendingRedirect.isNotEmpty) {
          editor.buffer = _pendingRedirect;
          editor.cursor = _pendingRedirect.length;
          _pendingRedirect = '';
        }
        final line = _raw
            ? await _readLineRaw(
                editor,
                _multiline.inBlock ? continuationPrompt : prompt,
              )
            : _readLineFallback(
                _multiline.inBlock ? continuationPrompt : prompt,
              );
        if (line == null) {
          _out.writeln();
          break;
        }
        final submitted = _multiline.submit(line);
        if (submitted == null) continue;
        editor.remember(submitted);
        if (_raw) {
          final progress = TuiProgress(onUpdate: (_) {}, onCancel: onCancelKey);
          onTurnStart?.call(progress);
          final outcome = await _handleWithProgress(progress, submitted);
          if (outcome.clear) _out.write('\x1B[2J\x1B[H');
          for (final text in outcome.lines) {
            _out.writeln(_colorize(text));
          }
          if (outcome.exit) break;
        } else {
          final outcome = await handler(submitted);
          if (outcome.clear) _out.write('\x1B[2J\x1B[H');
          for (final text in outcome.lines) {
            _out.writeln(_colorize(text));
          }
          if (outcome.exit) break;
        }
      }
    } finally {
      await historyStore?.save(history);
      _input?.dispose();
      _disableRawMode();
    }
  }

  /// Jalankan handler sambil merender spinner + status live (raw mode) dan
  /// mengawasi Ctrl-C. Byte lain yang diketik pengguna selama turn diabaikan
  /// (tidak dimasukkan ke editor) — byte yang sudah ter-buffer tetap aman.
  Future<TuiOutcome> _handleWithProgress(
    TuiProgress progress,
    String submitted,
  ) async {
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    var frame = 0;
    _out.write('\x1B[2K\r${_paint(frames[frame], '36')} ${progress.label}');
    frame++;
    final outcomeFuture = handler(submitted);
    final done = Completer<void>();
    unawaited(outcomeFuture.whenComplete(done.complete));

    var interrupted = false;
    final redirect = StringBuffer();
    // Setelah EOF, sumber input tidak akan pernah berisi data lagi — pakai
    // future yang tidak pernah selesai agar loop spin murni oleh tick timer.
    final pendingIdle = Completer<List<int>?>().future;
    var pending = _inputBuffer.next();
    try {
      while (!done.isCompleted) {
        // Escape key (0x1B) saat turn berjalan juga membatalkan (parity
        // Claude Code). Ctrl-C (0x03) tetap didukung.
        final result = await Future.any<Object?>([
          pending.then<Object?>((c) => c),
          Future<Object?>.delayed(const Duration(milliseconds: 90))
              .then<Object?>((_) => 'tick'),
        ]);
        if (result != 'tick') {
          final chunk = result as List<int>?;
          if (chunk == null) {
            pending = pendingIdle;
            continue;
          }
          pending = _inputBuffer.next();
          if (chunk.contains(0x03) || chunk.contains(0x1B)) {
            interrupted = true;
            progress.cancelled();
          } else {
            // E1: ketikan saat turn diarahkan ke prompt berikutnya.
            redirect.write(utf8.decode(chunk, allowMalformed: true)
                .replaceAll(RegExp('[\x00-\x1F\x7F]'), ''));
          }
        } else {
          _out.write('\x1B[2K\r${_paint(frames[frame % frames.length], '36')}'
              ' ${progress.label}');
          frame++;
        }
      }
      if (interrupted) {
        _out.write('\x1B[2K\r${_paint('✗ dibatalkan (menunggu runtime)', '33')}');
      }
    } finally {
      _out.write('\x1B[2K\r');
    }
    if (interrupted && redirect.isNotEmpty) {
      _pendingRedirect = redirect.toString();
    }
    return outcomeFuture;
  }

  String _colorize(String text) {
    if (!_color) return text;
    if (text.startsWith('tiko>') ||
        text.startsWith('╭') ||
        text.startsWith('╰')) {
      return _paint(text, '36');
    }
    if (text.startsWith('✓') || text.startsWith('OK')) {
      return _paint(text, '32');
    }
    if (text.startsWith('error:') || text.startsWith('✗')) {
      return _paint(text, '31');
    }
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
    if (editor.buffer.isNotEmpty) _rerender(editor, label);
    final chunks = _inputBuffer;
    while (true) {
      final chunk = await chunks.next();
      if (chunk == null) {
        _out.writeln();
        return null;
      }
      for (final event in decodeKeys(chunk)) {
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
  }

  void _rerender(LineEditor editor, String label) {
    final cursorCol = label.length + editor.cursor;
    _out.write('\x1B[2K\r$label${editor.buffer}\x1B[1G\x1B[${cursorCol + 1}C');
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
