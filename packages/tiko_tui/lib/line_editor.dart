/// Terminal UI engine (Hermes-parity): raw-mode line editing with history,
/// tab autocomplete and multiline input, shared by the Tiko and Simpul CLIs.
library;

/// A single decoded key event from a terminal byte sequence.
enum KeyType {
  char,
  enter,
  backspace,
  delete,
  left,
  right,
  up,
  down,
  home,
  end,
  tab,
  shiftTab,
  ctrlA,
  ctrlE,
  ctrlK,
  ctrlU,
  ctrlW,
  ctrlC,
  ctrlD,
  unknown,
}

class KeyEvent {
  const KeyEvent(this.type, [this.char = '']);

  final KeyType type;
  final String char;
}

/// Decodes terminal input bytes into [KeyEvent]s. Handles the common ANSI
/// sequences (CSI A/B/C/D/H/F, ~3/~1) and control characters; unknown bytes
/// are ignored so that paste bursts never inject garbage.
List<KeyEvent> decodeKeys(List<int> bytes) {
  final events = <KeyEvent>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1B) {
      if (i + 2 < bytes.length && bytes[i + 1] == 0x5B) {
        final code = bytes[i + 2];
        switch (code) {
          case 0x41:
            events.add(const KeyEvent(KeyType.up));
          case 0x42:
            events.add(const KeyEvent(KeyType.down));
          case 0x43:
            events.add(const KeyEvent(KeyType.right));
          case 0x44:
            events.add(const KeyEvent(KeyType.left));
          case 0x48:
            events.add(const KeyEvent(KeyType.home));
          case 0x46:
            events.add(const KeyEvent(KeyType.end));
          case 0x5A:
            events.add(const KeyEvent(KeyType.shiftTab));
          case 0x31 || 0x33 || 0x34:
            final terminated =
                i + 3 < bytes.length && bytes[i + 3] == 0x7E;
            if (!terminated) {
              events.add(const KeyEvent(KeyType.unknown));
              i += 3;
              continue;
            }
            events.add(
              KeyEvent(
                switch (code) {
                  0x31 => KeyType.home,
                  0x33 => KeyType.delete,
                  _ => KeyType.end,
                },
              ),
            );
            i += 4;
            continue;
          default:
            events.add(const KeyEvent(KeyType.unknown));
        }
        i += 3;
        continue;
      }
      i++;
      continue;
    }
    switch (b) {
      case 0x0D || 0x0A:
        events.add(const KeyEvent(KeyType.enter));
      case 0x7F || 0x08:
        events.add(const KeyEvent(KeyType.backspace));
      case 0x09:
        events.add(const KeyEvent(KeyType.tab));
      case 0x01:
        events.add(const KeyEvent(KeyType.ctrlA));
      case 0x05:
        events.add(const KeyEvent(KeyType.ctrlE));
      case 0x0B:
        events.add(const KeyEvent(KeyType.ctrlK));
      case 0x15:
        events.add(const KeyEvent(KeyType.ctrlU));
      case 0x17:
        events.add(const KeyEvent(KeyType.ctrlW));
      case 0x03:
        events.add(const KeyEvent(KeyType.ctrlC));
      case 0x04:
        events.add(const KeyEvent(KeyType.ctrlD));
      default:
        if (b >= 0x20) {
          events.add(KeyEvent(KeyType.char, _decodeUtf8(bytes, i, (n) => i = n)));
          continue;
        }
    }
    i++;
  }
  return events;
}

String _decodeUtf8(List<int> bytes, int start, void Function(int) advance) {
  final b = bytes[start];
  if (b < 0x80) {
    advance(start + 1);
    return String.fromCharCode(b);
  }
  int length;
  int value;
  if (b & 0xE0 == 0xC0) {
    length = 2;
    value = b & 0x1F;
  } else if (b & 0xF0 == 0xE0) {
    length = 3;
    value = b & 0x0F;
  } else {
    length = 4;
    value = b & 0x07;
  }
  for (var k = 1; k < length && start + k < bytes.length; k++) {
    value = (value << 6) | (bytes[start + k] & 0x3F);
  }
  advance(start + length);
  return String.fromCharCode(value);
}

/// Editable single line with cursor, word motions, kill ring and history
/// navigation. Pure state machine — no I/O — so it is fully unit-testable.
class LineEditor {
  LineEditor({List<String>? history, this.completer})
      : history = history ?? [],
        _historyIndex = (history ?? []).length;

  final List<String> history;
  final List<String> Function(String prefix, String token)? completer;

  String buffer = '';
  int cursor = 0;
  int _historyIndex = 0;
  String _draft = '';
  String? _kill;
  List<String> _candidates = const [];
  int _candidateIndex = -1;
  String _completionToken = '';
  String _lastInserted = '';

  bool get isEmpty => buffer.isEmpty;

  void insert(String text) {
    buffer = buffer.substring(0, cursor) + text + buffer.substring(cursor);
    cursor += text.length;
    _resetCompletion();
  }

  void backspace() {
    if (cursor == 0) return;
    buffer = buffer.substring(0, cursor - 1) + buffer.substring(cursor);
    cursor--;
    _resetCompletion();
  }

  void deleteForward() {
    if (cursor >= buffer.length) return;
    buffer = buffer.substring(0, cursor) + buffer.substring(cursor + 1);
    _resetCompletion();
  }

  void moveLeft() {
    if (cursor > 0) cursor--;
    _resetCompletion();
  }

  void moveRight() {
    if (cursor < buffer.length) cursor++;
    _resetCompletion();
  }

  void moveWordLeft() {
    while (cursor > 0 && buffer[cursor - 1] == ' ') {
      cursor--;
    }
    while (cursor > 0 && buffer[cursor - 1] != ' ') {
      cursor--;
    }
    _resetCompletion();
  }

  void moveWordRight() {
    while (cursor < buffer.length && buffer[cursor] == ' ') {
      cursor++;
    }
    while (cursor < buffer.length && buffer[cursor] != ' ') {
      cursor++;
    }
    _resetCompletion();
  }

  void home() {
    cursor = 0;
    _resetCompletion();
  }

  void end() {
    cursor = buffer.length;
    _resetCompletion();
  }

  void killToEnd() {
    _kill = buffer.substring(cursor);
    buffer = buffer.substring(0, cursor);
    _resetCompletion();
  }

  void killToStart() {
    _kill = buffer.substring(0, cursor);
    buffer = buffer.substring(cursor);
    cursor = 0;
    _resetCompletion();
  }

  void killWordBefore() {
    final stop = cursor;
    moveWordLeft();
    _kill = buffer.substring(cursor, stop);
    buffer = buffer.substring(0, cursor) + buffer.substring(stop);
    _resetCompletion();
  }

  void yank() {
    if (_kill != null) insert(_kill!);
  }

  void historyUp() {
    if (history.isEmpty) return;
    if (_historyIndex == history.length) _draft = buffer;
    if (_historyIndex > 0) _historyIndex--;
    buffer = history[_historyIndex];
    cursor = buffer.length;
    _resetCompletion();
  }

  void historyDown() {
    if (history.isEmpty || _historyIndex >= history.length) return;
    _historyIndex++;
    buffer = _historyIndex == history.length ? _draft : history[_historyIndex];
    cursor = buffer.length;
    _resetCompletion();
  }

  /// Tab completion: completes the trailing token via [completer]. A single
  /// candidate is inserted at once; multiple candidates cycle on repeated
  /// tabs and are returned for display.
  List<String> complete() {
    final completer = this.completer;
    if (completer == null) return const [];
    final tokenStart = buffer.lastIndexOf(' ', cursor - 1) + 1;
    final token = buffer.substring(tokenStart, cursor);
    if (_candidates.isNotEmpty &&
        (token == _completionToken || token == _lastInserted)) {
      _candidateIndex = (_candidateIndex + 1) % (_candidates.length + 1);
      final replacement = _candidateIndex == _candidates.length
          ? _completionToken
          : _candidates[_candidateIndex];
      buffer = buffer.substring(0, tokenStart) +
          replacement +
          buffer.substring(cursor);
      cursor = tokenStart + replacement.length;
      _lastInserted = replacement;
      return _candidates;
    }
    final prefix = buffer.substring(0, tokenStart);
    _candidates = completer(prefix, token);
    _completionToken = token;
    _lastInserted = '';
    if (_candidates.isEmpty) return const [];
    final common = _commonPrefix(_candidates);
    final replacement = common.length > token.length ? common : _candidates.first;
    buffer = buffer.substring(0, tokenStart) +
        replacement +
        buffer.substring(cursor);
    cursor = tokenStart + replacement.length;
    _lastInserted = replacement;
    _candidateIndex = _candidates.indexOf(replacement);
    return _candidates;
  }

  void _resetCompletion() {
    _candidates = const [];
    _candidateIndex = -1;
    _completionToken = '';
    _lastInserted = '';
  }

  static String _commonPrefix(List<String> values) {
    if (values.isEmpty) return '';
    var prefix = values.first;
    for (final value in values.skip(1)) {
      var k = 0;
      while (k < prefix.length &&
          k < value.length &&
          prefix[k] == value[k]) {
        k++;
      }
      prefix = prefix.substring(0, k);
    }
    return prefix;
  }

  /// Applies one event; returns true when the line should be submitted.
  bool handle(KeyEvent event) {
    switch (event.type) {
      case KeyType.enter:
        return true;
      case KeyType.char:
        insert(event.char);
      case KeyType.backspace:
        backspace();
      case KeyType.delete:
        deleteForward();
      case KeyType.left:
        moveLeft();
      case KeyType.right:
        moveRight();
      case KeyType.up:
        historyUp();
      case KeyType.down:
        historyDown();
      case KeyType.home:
        home();
      case KeyType.end:
        end();
      case KeyType.tab:
        complete();
      case KeyType.shiftTab:
        complete();
      case KeyType.ctrlA:
        home();
      case KeyType.ctrlE:
        end();
      case KeyType.ctrlK:
        killToEnd();
      case KeyType.ctrlU:
        killToStart();
      case KeyType.ctrlW:
        killWordBefore();
      case KeyType.ctrlC:
        buffer = '';
        cursor = 0;
        _resetCompletion();
      case KeyType.ctrlD || KeyType.unknown:
        break;
    }
    return false;
  }

  /// Appends a submitted line to history (deduplicated, most recent last).
  void remember(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    history.remove(trimmed);
    history.add(trimmed);
    _historyIndex = history.length;
    _draft = '';
  }
}

/// Collects submitted lines into a logical command, supporting two multiline
/// styles: a trailing backslash continues the line, and a `/begin` … `/end`
/// block captures everything verbatim (Hermes-style multiline entry).
class MultilineBuffer {
  final List<String> _lines = [];
  bool _inBlock = false;

  bool get inBlock => _inBlock;

  /// Returns the assembled input when complete, otherwise null.
  String? submit(String line) {
    if (_inBlock) {
      if (line.trim() == '/end') {
        _inBlock = false;
        final text = _lines.join('\n');
        _lines.clear();
        return text;
      }
      _lines.add(line);
      return null;
    }
    if (line.trim() == '/begin') {
      _inBlock = true;
      return null;
    }
    if (line.endsWith('\\') && !line.endsWith('\\\\')) {
      _lines.add(line.substring(0, line.length - 1));
      return null;
    }
    if (_lines.isNotEmpty) {
      _lines.add(line);
      final text = _lines.join('\n');
      _lines.clear();
      return text;
    }
    return line;
  }

  void reset() {
    _lines.clear();
    _inBlock = false;
  }
}
