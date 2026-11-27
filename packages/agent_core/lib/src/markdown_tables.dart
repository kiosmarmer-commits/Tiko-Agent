// Hermes parity: `agent/markdown_tables.py` — realignment ulang tabel
// markdown hasil model dengan lebar tampilan sadar-CJK/karakter-lebar.
//
// Model meng-pad tabel dengan asumsi satu sel per karakter; glyph CJK dan
// sebagian besar emoji lebar dua sel, sehingga baris body bergeser ke kanan
// di terminal nyata. Port ini membangun ulang padding dengan lebar tampilan
// sendiri (implementasi wcwidth-lite tanpa dependensi) sambil mempertahankan
// pipe/dash. Sengaja konservatif: hanya blok `| ... |` ber-d-divider yang
// ditulis ulang; fragmen satu baris/tengah-stream lewat apa adanya (caller
// buffer baris dan flush blok lengkap).
//
// Deviasi sadar: `wcswidth` yang mengembalikan -1 untuk sebagian sekuens
// emoji+variation-selector di-clamp ke 0 (drift 1-sel mengalahkan melebarkan
// semua tabel) — diport sebagai width 0 untuk variation selector dan
// combining mark.
library;

const int _minColWidth = 3;

final _dividerCellRe = RegExp(r'^\s*:?-{3,}:?\s*$');

/// Lebar tampilan string: CJK/emoji wide = 2, combining mark & variation
/// selector = 0, lainnya = 1 (wcwidth-lite, never-raises, >= 0).
int dispWidth(String s) {
  var w = 0;
  var i = 0;
  while (i < s.length) {
    final unit = s.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < s.length) {
      final low = s.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        final cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        w += _codePointWidth(cp);
        i += 2;
        continue;
      }
    }
    w += _codePointWidth(unit);
    i += 1;
  }
  return w;
}

bool _inRanges(int cp, List<List<int>> ranges) {
  var lo = 0;
  var hi = ranges.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final r = ranges[mid];
    if (cp < r[0]) {
      hi = mid - 1;
    } else if (cp > r[1]) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

const List<List<int>> _wideRanges = [
  [0x1100, 0x115F], // Hangul Jamo
  [0x2E80, 0x303E], // CJK Radicals .. CJK Symbols
  [0x3041, 0x33FF], // Hiragana .. CJK Compatibility
  [0x3400, 0x4DBF], // CJK Ext A
  [0x4E00, 0x9FFF], // CJK Unified
  [0xA000, 0xA4CF], // Yi
  [0xA960, 0xA97F], // Hangul Jamo Ext A
  [0xAC00, 0xD7A3], // Hangul Syllables
  [0xF900, 0xFAFF], // CJK Compatibility Ideographs
  [0xFE10, 0xFE19], // Vertical forms
  [0xFE30, 0xFE6F], // CJK Compatibility Forms
  [0xFF00, 0xFF60], // Fullwidth Forms
  [0xFFE0, 0xFFE6], // Fullwidth Signs
  [0x1F300, 0x1F64F], // Emoji pictograms
  [0x1F900, 0x1F9FF], // Supplemental Symbols and Pictographs
  [0x20000, 0x2FFFD], // CJK Ext B+
  [0x30000, 0x3FFFD], // CJK Ext G+
];

const List<List<int>> _zeroRanges = [
  [0x0300, 0x036F], // Combining Diacritical Marks
  [0x200B, 0x200F], // Zero-width & direction marks
  [0xFE00, 0xFE0F], // Variation selectors
  [0x20D0, 0x20FF], // Combining marks for symbols
];

int _codePointWidth(int cp) {
  if (_inRanges(cp, _zeroRanges)) return 0;
  if (_inRanges(cp, _wideRanges)) return 2;
  return 1;
}

bool _isSpaceAt(String row, int pos) =>
    pos < 0 || pos >= row.length || _isSpaceUnit(row.codeUnitAt(pos));

// Python str.isspace() untuk ASCII/BMP umum.
bool _isSpaceUnit(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0A ||
    unit == 0x0B ||
    unit == 0x0C ||
    unit == 0x0D ||
    unit == 0x85 ||
    unit == 0xA0 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x3000;

bool _isAsciiAlpha(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

final _contractionTailRe = RegExp(r'(?:[stdm]|ll|re|ve)(?![A-Za-z])',
    caseSensitive: false);

/// Run backtick `row[start:end]` adalah satu sel utuh: whitespace lalu pipe
/// atau tepi baris di kedua sisi. Run yang menyentuh pipe (`` `| grep` ``,
/// `` `cat |` ``) membuka/menutup code yang memegangnya.
bool _fillsCell(String row, int start, int end) {
  var left = start;
  while (left > 0 && _isSpaceUnit(row.codeUnitAt(left - 1))) {
    left -= 1;
  }
  var right = end;
  while (right < row.length && _isSpaceUnit(row.codeUnitAt(right))) {
    right += 1;
  }
  return ((left == 0 ||
              (row.codeUnitAt(left - 1) == 0x7C /* | */ && left < start)) &&
          (right == row.length ||
              (row.codeUnitAt(right) == 0x7C /* | */ && right > end)));
}

/// Satu backtick yang diketik sebagai apostrophe dalam kata ASCII
/// (`don`t`).
bool _isApostrophe(String row, int start, int end) {
  if (end - start != 1 || start <= 0) return false;
  final prev = row.codeUnitAt(start - 1);
  return prev < 0x80 &&
      _isAsciiAlpha(prev) &&
      _contractionTailRe.matchAsPrefix(row, end) != null;
}

/// Pasangan backtick yang melintasi pipe ber-spasi tanpa menjadi code:
/// opener yang diketik sebagai apostrophe (`don`t | it`s`), opener yang
/// mengakhiri kata sebelumnya, closer yang memulai kata sesudahnya, atau
/// kedua run sendirian di selnya masing-masing. Code yang menempel ke teks
/// di luarnya (``run`ls | grep x`now``) tetap code: hanya contraction tail
/// ASCII yang dihitung apostrophe.
bool _notACodeSpan(String row, int opener, int openerEnd, int closingEnd) {
  final closer = closingEnd - (openerEnd - opener);
  bool spaceAt(int pos) => _isSpaceAt(row, pos);
  return _isApostrophe(row, opener, openerEnd) ||
      (spaceAt(openerEnd) &&
          !spaceAt(opener - 1) &&
          row.codeUnitAt(opener - 1) != 0x7C) ||
      (spaceAt(closer - 1) && !spaceAt(closingEnd)) ||
      (_fillsCell(row, opener, openerEnd) &&
          _fillsCell(row, closer, closingEnd));
}

/// Pecahkan baris GFM pada pipe tak-escape di luar inline-code span yang
/// berpasangan.
List<String> splitTableRow(String row) {
  // Pre-index run berdasar lebar delimiter: backtick tak berpasangan tidak
  // boleh memindai ulang seluruh baris panjang hasil model.
  final nextRun = <int, int>{};
  final matchingEnds = <int, int>{};
  var scan = row.length - 1;
  while (scan >= 0) {
    if (row.codeUnitAt(scan) != 0x60 /* ` */) {
      scan -= 1;
      continue;
    }
    final end = scan + 1;
    while (scan >= 0 && row.codeUnitAt(scan) == 0x60) {
      scan -= 1;
    }
    final start = scan + 1;
    final width = end - start;
    if (width > 1 && nextRun.containsKey(width - 1)) {
      matchingEnds[start + 1] = nextRun[width - 1]!;
    }
    if (nextRun.containsKey(width)) {
      matchingEnds[start] = nextRun[width]!;
    }
    nextRun[width] = end;
  }

  final cellEdges = <int>[
    for (final m in ' | '.allMatches(row)) m.start + 1,
  ];
  final separators = <int>[];
  var i = 0;
  while (i < row.length) {
    if (row.codeUnitAt(i) == 0x5C /* \ */) {
      final slashStart = i;
      while (i < row.length && row.codeUnitAt(i) == 0x5C) {
        i += 1;
      }
      if ((i - slashStart).isOdd && i < row.length) {
        i += 1; // karakter berikutnya di-escape, termasuk pipe/backtick
      }
      continue;
    }
    if (row.codeUnitAt(i) == 0x60 /* ` */) {
      var end = i + 1;
      while (end < row.length && row.codeUnitAt(end) == 0x60) {
        end += 1;
      }
      final closingEnd = matchingEnds[i];
      if (closingEnd != null) {
        var edge = 0;
        while (edge < cellEdges.length && cellEdges[edge] < end) {
          edge += 1;
        }
        final withinCell =
            edge == cellEdges.length || cellEdges[edge] >= closingEnd - (end - i);
        if (withinCell || !_notACodeSpan(row, i, end, closingEnd)) {
          i = closingEnd;
          continue;
        }
      }
      i = end; // backtick tak berpasangan / lintas-sel adalah literal
      continue;
    }
    if (row.codeUnitAt(i) == 0x7C /* | */) {
      separators.add(i);
    }
    i += 1;
  }

  var start = 0;
  var end = row.length;
  if (separators.isNotEmpty && row.substring(0, separators.first).trim().isEmpty) {
    start = separators.first + 1;
  }
  if (separators.isNotEmpty &&
      row.substring(separators.last + 1).trim().isEmpty) {
    end = separators.last;
  }
  if (start > end) return [''];

  final cells = <String>[];
  var cellStart = start;
  for (final separator in separators) {
    if (start <= separator && separator < end) {
      cells.add(row.substring(cellStart, separator).trim());
      cellStart = separator + 1;
    }
  }
  cells.add(row.substring(cellStart, end).trim());
  return cells;
}

/// True bila [row] adalah baris pemisah tabel markdown.
bool isTableDivider(String row) {
  final cells = splitTableRow(row);
  return cells.length > 1 && cells.every(_dividerCellRe.hasMatch);
}

/// True bila [row] mungkin baris tabel markdown. Sengaja permisif untuk
/// caller streaming (false positive paling banter menunda cetak satu
/// baris). Pipe awal sinyal terkuat; tanpa itu >= 2 pipe diterima.
bool looksLikeTableRow(String row) {
  final stripped = row.trim();
  return stripped.isNotEmpty &&
      (stripped.startsWith('|') || '|'.allMatches(stripped).length >= 2);
}

List<String> _renderBlock(List<List<String>> rows, int? availableWidth) {
  final ncols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  final padded = [
    for (final r in rows) [...r, for (var k = r.length; k < ncols; k++) ''],
  ];
  final widths = [
    for (var c = 0; c < ncols; c++)
      padded.map((r) => dispWidth(r[c])).reduce((a, b) => a > b ? a : b) <
              _minColWidth
          ? _minColWidth
          : padded.map((r) => dispWidth(r[c])).reduce((a, b) => a > b ? a : b),
  ];
  if (availableWidth != null &&
      widths.fold<int>(0, (a, b) => a + b) + 3 * ncols + 1 >
          (availableWidth > 20 ? availableWidth : 20)) {
    return _renderVertical(padded, ncols, availableWidth);
  }

  String rowLine(List<String> cells) {
    final buf = StringBuffer('| ');
    for (var k = 0; k < cells.length; k++) {
      if (k > 0) buf.write(' | ');
      final w = widths[k] - dispWidth(cells[k]);
      buf.write(cells[k]);
      if (w > 0) buf.write(' ' * w);
    }
    buf.write(' |');
    return buf.toString();
  }

  final out = <String>[
    rowLine(padded.first),
    '|${widths.map((w) => '-' * (w + 2)).join('|')}|',
    for (final r in padded.skip(1)) rowLine(r),
  ];
  return out;
}

/// Pecahkan satu kata yang terlalu lebar menjadi chunk lebar `w`.
List<String> _hardBreak(String word, int w) {
  final out = <String>[];
  var buf = '';
  var bw = 0;
  for (final ch in word.runes) {
    final c = String.fromCharCode(ch);
    final cw = dispWidth(c) == 0 ? 1 : dispWidth(c);
    if (bw + cw > w && buf.isNotEmpty) {
      out.add(buf);
      buf = c;
      bw = cw;
    } else {
      buf = buf + c;
      bw += cw;
    }
  }
  if (buf.isNotEmpty) out.add(buf);
  return out;
}

/// Soft-wrap teks di batas kata ke `width` sel tampilan; kata lebih lebar
/// dari width di-hard-break. Input kosong → satu string kosong.
List<String> _wrapToWidth(String text, int width) {
  if (width <= 0 || text.isEmpty) return [text];
  final words = text
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return [''];
  final lines = <String>[];
  var current = '';
  var currentW = 0;
  void start(String word, int ww) {
    if (ww <= width) {
      current = word;
      currentW = ww;
    } else {
      final pieces = _hardBreak(word, width);
      lines.addAll(pieces.sublist(0, pieces.length - 1));
      current = pieces.isEmpty ? '' : pieces.last;
      currentW = dispWidth(current);
    }
  }

  for (final word in words) {
    final ww = dispWidth(word);
    if (current.isEmpty) {
      start(word, ww);
    } else if (currentW + 1 + ww <= width) {
      current = '$current $word';
      currentW += 1 + ww;
    } else {
      lines.add(current);
      start(word, ww);
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.isEmpty ? [''] : lines;
}

/// Tabel terlalu lebar → blok `Header: value` (fallback sempit ala Claude
/// Code); tiap baris body jadi satu blok dengan continuation indent dua
/// spasi, blok dipisah garis `─`.
List<String> _renderVertical(
  List<List<String>> rows,
  int ncols,
  int availableWidth,
) {
  if (rows.isEmpty) return [];
  final labels = [
    for (var i = 0; i < ncols; i++)
      i < rows.first.length && rows.first[i].isNotEmpty
          ? rows.first[i]
          : 'Kolom ${i + 1}',
  ];
  final sepLen = (availableWidth - 2).clamp(20, 40);
  final separator = '─' * sepLen;
  final contBudget = availableWidth - 2 > 10 ? availableWidth - 2 : 10;
  final out = <String>[];
  for (var ri = 1; ri < rows.length; ri++) {
    if (ri > 1) out.add(separator);
    final row = rows[ri];
    for (var ci = 0; ci < labels.length; ci++) {
      final label = labels[ci];
      final value = ci < row.length ? row[ci] : '';
      if (value.isEmpty) {
        out.add('$label:');
        continue;
      }
      final budget =
          availableWidth - dispWidth(label) - 2 > 10
              ? availableWidth - dispWidth(label) - 2
              : 10;
      final wrapped = _wrapToWidth(value, budget);
      out.add('$label: ${wrapped.first}');
      if (wrapped.length > 1) {
        for (final cl in _wrapToWidth(wrapped.sublist(1).join(' '), contBudget)) {
          if (cl.trim().isNotEmpty) out.add('  $cl');
        }
      }
    }
  }
  return out;
}

/// Tulis ulang setiap blok `| ... |` + divider dengan padding sadar-lebar.
/// Baris non-tabel dikembalikan verbatim — aman pada prosa apa pun. Dengan
/// [availableWidth] (sel terminal), tabel lebih lebar dari itu dirender
/// vertikal key-value alih-alih soft-wrap mid-cell.
String realignMarkdownTables(String text, {int? availableWidth}) {
  if (!text.contains('|')) return text;
  final lines = text.split('\n');
  final out = <String>[];
  var i = 0;
  final n = lines.length;
  while (i < n) {
    final line = lines[i];
    if (line.contains('|') &&
        i + 1 < n &&
        isTableDivider(lines[i + 1])) {
      final header = splitTableRow(line);
      final body = <List<String>>[];
      var j = i + 2;
      while (j < n && lines[j].contains('|') && lines[j].trim().isNotEmpty) {
        if (!isTableDivider(lines[j])) {
          body.add(splitTableRow(lines[j]));
        }
        j += 1;
      }
      if (header.any((c) => c.isNotEmpty) || body.isNotEmpty) {
        out.addAll(_renderBlock([header, ...body], availableWidth));
        i = j;
        continue;
      }
    }
    out.add(line);
    i += 1;
  }
  return out.join('\n');
}
