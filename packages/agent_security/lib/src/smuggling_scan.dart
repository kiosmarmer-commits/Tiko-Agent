/// Deteksi terminal-smuggling pada teks perintah shell sebelum approval
/// (Hermes `approval_ansi_c.py`, `approval_quoted_newlines.py`,
/// `approval_variation_selectors.py`).
///
/// Perintah berasal dari LLM utama yang bisa ter-prompt-inject; escape
/// sequence terminal, newline tersembunyi dalam quoted string, dan karakter
/// unicode tak terlihat adalah vektor klasik untuk menyelundupkan eksekusi
/// atau memanipulasi tampilan approval. Scanner ini deterministik (tanpa
/// jaringan, tanpa LLM) dan hanya melaporkan temuan — keputusan deny tetap
/// milik pemanggil (mis. [ShellPolicy.check]).
class SmugglingHit {
  const SmugglingHit({
    required this.kind,
    required this.position,
    required this.snippet,
    required this.description,
  });

  /// 'ansi_escape' | 'osc_sequence' | 'quoted_newline' | 'invisible_unicode'
  final String kind;
  final int position;
  final String snippet;
  final String description;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'position': position,
        'snippet': snippet,
        'description': description,
      };
}

class SmugglingScan {
  const SmugglingScan._();

  /// ANSI escape: CSI (`ESC[...final`), OSC (`ESC]...BEL/ST`), dan escape
  /// tunggal apa pun (`ESC` + satu karakter). Cukup mendeteksi keberadaan
  /// `ESC` (0x1B) — teks perintah shell yang sah tidak butuh escape terminal.
  static final _esc = RegExp('\x1B');

  static const _oscIntroCode = 0x5D; // ']'

  /// Karakter unicode tak terlihat: soft hyphen, zero-width, bidi controls,
  /// variation selectors, dan tag characters.
  static bool _isInvisibleUnicode(int code) {
    return (code >= 0x00AD && code <= 0x00AD) ||
        (code >= 0x200B && code <= 0x200F) ||
        (code >= 0x202A && code <= 0x202E) ||
        (code >= 0x2060 && code <= 0x2064) ||
        (code >= 0x2066 && code <= 0x206F) ||
        (code >= 0xFE00 && code <= 0xFE0F) ||
        (code >= 0xE0000 && code <= 0xE007F);
  }

  /// Memindai [command] dan mengembalikan semua temuan smuggling. Kosong
  /// berarti bersih. Urutan hasil: posisi naik.
  static List<SmugglingHit> scan(String command) {
    final hits = <SmugglingHit>[];
    for (final m in _esc.allMatches(command)) {
      final isOsc = m.start + 1 < command.length &&
          command.codeUnitAt(m.start + 1) == _oscIntroCode;
      hits.add(
        SmugglingHit(
          kind: isOsc ? 'osc_sequence' : 'ansi_escape',
          position: m.start,
          snippet: _snippetAt(command, m.start),
          description: isOsc
              ? 'OSC terminal sequence (hyperlink/title/clipboard smuggling)'
              : 'ANSI escape sequence di teks perintah',
        ),
      );
    }

    hits.addAll(_scanQuotedNewlines(command));

    final runes = command.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final code = runes[i];
      if (!_isInvisibleUnicode(code)) continue;
      hits.add(
        SmugglingHit(
          kind: 'invisible_unicode',
          position: i,
          snippet: _snippetAt(command, i),
          description:
              'Karakter unicode tak terlihat (U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')})',
        ),
      );
    }
    hits.sort((a, b) => a.position.compareTo(b.position));
    return hits;
  }

  /// Newline di dalam quoted string shell ('...' atau "...") menyembunyikan
  /// perintah tambahan dari tampilan satu baris. Backslash-escape di dalam
  /// double quote dihormati; single quote tidak mengenal escape.
  static Iterable<SmugglingHit> _scanQuotedNewlines(String command) sync* {
    String? quote;
    var escaped = false;
    for (var i = 0; i < command.length; i++) {
      final ch = command[i];
      if (quote == '"' && escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote == null && (ch == "'" || ch == '"')) {
        quote = ch;
        continue;
      }
      if (quote != null && ch == quote) {
        quote = null;
        continue;
      }
      if (quote != null && (ch == '\n' || ch == '\r')) {
        yield SmugglingHit(
          kind: 'quoted_newline',
          position: i,
          snippet: _snippetAt(command, i),
          description:
              'Newline tersembunyi di dalam quoted string (perintah tambahan tidak terlihat)',
        );
      }
    }
  }

  static String _snippetAt(String command, int position) {
    final start = position - 12 < 0 ? 0 : position - 12;
    final end = position + 12 > command.length ? command.length : position + 12;
    return command
        .substring(start, end)
        .replaceAll('\x1B', 'ESC')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
  }

  /// True bila [command] bersih dari semua pola smuggling.
  static bool isClean(String command) => scan(command).isEmpty;
}
