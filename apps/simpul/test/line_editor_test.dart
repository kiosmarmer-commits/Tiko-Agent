import 'package:simpul/tui/line_editor.dart';
import 'package:test/test.dart';

KeyEvent ch(String c) => KeyEvent(KeyType.char, c);

void type(LineEditor e, String text) {
  for (final event in decodeKeys(text.codeUnits)) {
    e.handle(event);
  }
}

void main() {
  test('decodeKeys memetakan ANSI dan kontrol ke event', () {
    final events = decodeKeys([
      0x1B, 0x5B, 0x41, // up
      0x1B, 0x5B, 0x43, // right
      0x1B, 0x5B, 0x33, 0x7E, // delete
      0x7F, // backspace
      0x09, // tab
      0x03, // ctrl-c
      0x61, 0xC3, 0xA9, // 'a', 'é'
    ]);
    expect(events.map((e) => e.type).toList(), [
      KeyType.up,
      KeyType.right,
      KeyType.delete,
      KeyType.backspace,
      KeyType.tab,
      KeyType.ctrlC,
      KeyType.char,
      KeyType.char,
    ]);
    expect(events.last.char, 'é');
  });

  test('editing dasar: insert, kursor, backspace, delete', () {
    final e = LineEditor();
    type(e, 'hello');
    expect(e.buffer, 'hello');
    e.handle(const KeyEvent(KeyType.left));
    e.handle(const KeyEvent(KeyType.left));
    e.handle(ch('X'));
    expect(e.buffer, 'helXlo');
    expect(e.cursor, 4);
    e.handle(const KeyEvent(KeyType.backspace));
    expect(e.buffer, 'hello');
    e.handle(const KeyEvent(KeyType.end));
    e.handle(const KeyEvent(KeyType.delete));
    expect(e.buffer, 'hello');
    e.handle(const KeyEvent(KeyType.home));
    e.handle(const KeyEvent(KeyType.delete));
    expect(e.buffer, 'ello');
  });

  test('pintasan Ctrl: A/E/K/U/W', () {
    final e = LineEditor();
    type(e, 'satu dua tiga');
    e.handle(const KeyEvent(KeyType.ctrlA));
    expect(e.cursor, 0);
    e.handle(const KeyEvent(KeyType.ctrlE));
    expect(e.cursor, e.buffer.length);
    e.handle(const KeyEvent(KeyType.ctrlW));
    expect(e.buffer, 'satu dua ');
    e.handle(const KeyEvent(KeyType.ctrlA));
    e.handle(const KeyEvent(KeyType.ctrlK));
    expect(e.buffer, '');
    e.handle(const KeyEvent(KeyType.ctrlU));
    expect(e.buffer, '');
  });

  test('history: naik/turun dengan draft terjaga', () {
    final e = LineEditor(history: ['/search a', '/health']);
    e.type2('/search b');
    e.handle(const KeyEvent(KeyType.up));
    expect(e.buffer, '/health');
    e.handle(const KeyEvent(KeyType.up));
    expect(e.buffer, '/search a');
    e.handle(const KeyEvent(KeyType.down));
    expect(e.buffer, '/health');
    e.handle(const KeyEvent(KeyType.down));
    expect(e.buffer, '/search b', reason: 'draft dikembalikan');
  });

  test('autocomplete: prefix sama dan siklus kandidat', () {
    final e = LineEditor(
      completer: (prefix, token) => [
        '/search',
        '/stats',
        '/sync-init',
      ].where((c) => c.startsWith(token)).toList(),
    );
    type(e, '/s');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/search', reason: 'kandidat pertama langsung diisi');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/stats', reason: 'siklus ke kandidat berikutnya');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/sync-init');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/s', reason: 'kembali ke token asli');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/search', reason: 'siklus berputar lagi');
  });

  test('autocomplete token kedua memakai posisi kursor', () {
    final e = LineEditor(
      completer: (prefix, token) =>
          ['catatan/a.md', 'catatan/b.md'].where((n) => n.startsWith(token)).toList(),
    );
    type(e, '/open catatan/');
    e.handle(const KeyEvent(KeyType.tab));
    expect(e.buffer, '/open catatan/a.md');
  });

  test('MultilineBuffer: backslash dan blok /begin /end', () {
    final m = MultilineBuffer();
    expect(m.submit('baris satu \\'), isNull);
    expect(m.submit('baris dua'), 'baris satu \nbaris dua');
    expect(m.submit('/begin'), isNull);
    expect(m.inBlock, isTrue);
    expect(m.submit('# judul'), isNull);
    expect(m.submit('isi \\'), isNull, reason: 'di dalam blok backslash verbatim');
    expect(m.submit('/end'), '# judul\nisi \\');
    expect(m.inBlock, isFalse);
  });

  test('enter mengembalikan true untuk submit', () {
    final e = LineEditor();
    type(e, 'hi');
    expect(e.handle(const KeyEvent(KeyType.enter)), isTrue);
  });
}

extension _Type on LineEditor {
  void type2(String text) {
    for (final event in decodeKeys(text.codeUnits)) {
      handle(event);
    }
  }
}
