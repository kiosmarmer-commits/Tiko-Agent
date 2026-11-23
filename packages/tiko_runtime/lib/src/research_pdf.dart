// Fase F4 — ekspor PDF minimal laporan riset. Part dari library tiko_runtime
// (import dart:convert/dart:typed_data sudah ada di tiko_runtime.dart).
part of 'tiko_runtime.dart';

/// F4 (docs/15 §5) — ekspor PDF minimal untuk laporan riset, pure Dart
/// tanpa dependensi baru (kebijakan repo). Laporan markdown dirender sebagai
/// teks Helvetica A4 multi-halaman single-stream; struktur PDF deterministik
/// dan dapat diuji tanpa parser eksternal.
Uint8List buildPdfReport(String markdown) {
  final lines = _renderLines(markdown);
  final pages = <List<String>>[];
  final perPage = 56;
  for (var i = 0; i < lines.length; i += perPage) {
    pages.add(
      lines.sublist(i, i + perPage > lines.length ? lines.length : i + perPage),
    );
  }
  if (pages.isEmpty) pages.add(const <String>[]);

  final buf = BytesBuilder();
  buf.add(const [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 0x0a]);

  final offsets = <int>[];
  void addObject(int num, String body) {
    offsets.add(buf.length);
    buf.add(latin1.encode('$num 0 obj\n$body\nendobj\n'));
  }

  // 1 catalog, 2 pages, 3 font, lalu pasangan (page, content) mulai 4.
  final firstContentObj = 4 + pages.length;
  final kids = [
    for (var i = 0; i < pages.length; i++) '${4 + i} 0 R',
  ].join(' ');
  addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  addObject(
    2,
    '<< /Type /Pages /Count ${pages.length} /Kids [$kids] >>',
  );
  addObject(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (var p = 0; p < pages.length; p++) {
    final contentNum = firstContentObj + p;
    final stream = _contentStream(pages[p]);
    addObject(
      4 + p,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
      '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentNum 0 R >>',
    );
    addObject(
      contentNum,
      '<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream\n'
      'endstream',
    );
  }

  final xrefStart = buf.length;
  final xref = StringBuffer('xref\n0 ${offsets.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final off in offsets) {
    xref.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  buf.add(
    latin1.encode(
      '$xref'
      'trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefStart\n%%EOF\n',
    ),
  );
  return buf.toBytes();
}

String _contentStream(List<String> lines) {
  if (lines.isEmpty) {
    return 'BT /F1 11 Tf 14 TL 56 800 Td ET';
  }
  final body = lines
      .map((l) => '(${_escape(l)}) Tj T*')
      .join('\n');
  return 'BT /F1 11 Tf 14 TL 56 800 Td\n$body\nET';
}

/// Markdown → baris teks PDF: strip sintaks ringan, transliterasi karakter
/// non-latin1 umum, wrap ~100 char, buang karakter yang tak terwakili.
List<String> _renderLines(String markdown) {
  const translit = {
    '…': '...',
    '—': '-',
    '–': '-',
    '•': '-',
    '·': '-',
    '“': '"',
    '”': '"',
    '‘': "'",
    '’': "'",
    '×': 'x',
    '≈': '~',
    '≥': '>=',
    '≤': '<=',
    '±': '+/-',
    '→': '->',
    '←': '<-',
  };
  final out = <String>[];
  for (final rawLine in markdown.split('\n')) {
    var line = rawLine.trim();
    line = line.replaceAll(RegExp(r'^#{1,6}\s*'), '');
    line = line.replaceAll(RegExp(r'^>\s?'), '');
    line = line.replaceAll(RegExp(r'^(-{1,2}|\*)\s+'), '- ');
    line = line.replaceAll(RegExp(r'\*\*|__|`'), '');
    line = line.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\((https?://\S+)\)'),
      (m) => '${m.group(1)} (${m.group(2)})',
    );
    for (final e in translit.entries) {
      line = line.replaceAll(e.key, e.value);
    }
    line = line.runes.map((code) {
      if ((code >= 0x20 && code <= 0x7e) || (code >= 0xa0 && code <= 0xff)) {
        return String.fromCharCode(code);
      }
      return code < 0x20 ? '' : '?';
    }).join();
    if (line.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    while (line.length > 100) {
      var cut = line.lastIndexOf(' ', 100);
      if (cut < 40) cut = 100;
      out.add(line.substring(0, cut));
      line = line.substring(cut).trim();
    }
    out.add(line);
  }
  return out;
}

String _escape(String s) =>
    s.replaceAll('\\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
