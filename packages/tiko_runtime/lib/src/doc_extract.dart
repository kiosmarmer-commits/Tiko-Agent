import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A.3 — Ekstraktor teks dokumen best-effort, tanpa dependency biner.
///
/// Tujuan: dokumen yang di-attach user (PDF/DOCX/ODT/XLSX/PPTX/CSV) berubah
/// menjadi teks yang bisa dibaca agent, mirip cara Claude menangani upload
/// dokumen (non-PDF diekstrak teks, PDF multimodal). Semua jalur
/// fail-closed: kegagalan menghasilkan [ExtractAttempt.text] null + note
/// jujur — bukan exception yang menggagalkan pesan.
class ExtractAttempt {
  const ExtractAttempt({this.text, required this.note});

  /// Teks hasil ekstraksi (sudah dipotong ke [maxChars] bila diberikan);
  /// null bila ekstraksi gagal atau tidak menghasilkan teks.
  final String? text;
  final String note;
}

/// Ekstrak teks dari [bytes]. Keputusan tipe dari [mime] lalu ekstensi nama
/// file. [maxChars] membatasi panjang hasil dengan penanda jujur.
ExtractAttempt extractDocumentText({
  required String name,
  String? mime,
  required List<int> bytes,
  int maxChars = 64 * 1024,
}) {
  final m = (mime ?? '').toLowerCase().trim();
  final lname = name.toLowerCase().trim();
  bool ext(String e) => lname.endsWith(e);

  try {
    if (m == 'application/pdf' || ext('.pdf')) {
      return _limit(_extractPdf(bytes), maxChars, 'PDF');
    }
    if (m == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
        ext('.docx')) {
      return _limit(
        _extractOfficeXml(bytes, entryPattern: RegExp(r'^word/document\.xml$'),
            paragraphEnd: RegExp(r'</w:p>')),
        maxChars,
        'DOCX',
      );
    }
    if (m == 'application/vnd.oasis.opendocument.text' || ext('.odt')) {
      return _limit(
        _extractOfficeXml(bytes, entryPattern: RegExp(r'^content\.xml$'),
            paragraphEnd: RegExp(r'</text:p>')),
        maxChars,
        'ODT',
      );
    }
    if (m == 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
        ext('.xlsx')) {
      return _limit(_extractXlsx(bytes), maxChars, 'XLSX');
    }
    if (m == 'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
        ext('.pptx')) {
      return _limit(
        _extractPptx(bytes),
        maxChars,
        'PPTX',
      );
    }
    if (m.startsWith('text/') &&
        (m == 'text/csv' || m == 'text/plain' || m != 'text/html')) {
      final decoded = utf8.decode(bytes, allowMalformed: true);
      return _limit(decoded, maxChars, 'teks');
    }
    // Lampiran teks umum sering datang tanpa mime — putuskan dari ekstensi.
    const textExts = ['.txt', '.md', '.markdown', '.csv', '.log', '.json',
      '.yaml', '.yml', '.toml', '.xml', '.dart', '.py', '.js', '.ts',
      '.sh', '.html', '.htm'];
    if (m.isEmpty && textExts.any(ext)) {
      final decoded = utf8.decode(bytes, allowMalformed: true);
      return _limit(decoded, maxChars, 'teks');
    }
    return ExtractAttempt(
      text: null,
      note: 'tipe dokumen tidak didukung ekstraktor runtime',
    );
  } catch (e) {
    return ExtractAttempt(text: null, note: 'ekstraksi gagal: $e');
  }
}

ExtractAttempt _limit(String? raw, int maxChars, String label) {
  if (raw == null) {
    return ExtractAttempt(text: null, note: '$label tidak berisi teks');
  }
  final content = raw.trim();
  if (content.isEmpty) {
    return ExtractAttempt(text: null, note: '$label tidak berisi teks');
  }
  if (content.length > maxChars) {
    return ExtractAttempt(
      text: '${content.substring(0, maxChars)}\n'
          '[dipotong: ${content.length} total karakter, hanya '
          '$maxChars pertama yang diekstrak]',
      note: 'ekstraksi $label ok (dipotong)',
    );
  }
  return ExtractAttempt(text: content, note: 'ekstraksi $label ok');
}

// ---------------------------------------------------------------------------
// PDF (best-effort memitik konvensi PDF umum)
// ---------------------------------------------------------------------------

String? _extractPdf(List<int> bytes) {
  final header = latin1.decode(
    bytes.sublist(0, bytes.length >= 5 ? 5 : bytes.length),
    allowInvalid: true,
  );
  if (!header.startsWith('%PDF')) {
    throw const FormatException('tanda tangan %PDF tidak ditemukan');
  }
  final buf = StringBuffer();
  var found = 0;
  final data = Uint8List.fromList(bytes);

  // Cari semua pasangan `stream ... endstream` lalu inflate yang Flate.
  final streamStart = 'stream'.codeUnits;
  var i = 0;
  while (i < data.length - 7) {
    var match = true;
    for (var k = 0; k < 6; k++) {
      if (data[i + k] != streamStart[k]) {
        match = false;
        break;
      }
    }
    if (match) {
      final after = i + 6;
      final eol = _skipEol(data, after);
      final end = _findEndstream(data, eol);
      if (end == null) {
        i = after;
        continue;
      }
      final chunk = data.sublist(eol, end);
      final text = _tryInflate(chunk);
      if (text != null) found += _extractPdfTextOps(text, buf);
      i = end + 9;
    } else {
      i++;
    }
  }
  if (found == 0) return null;
  final out = buf.toString();
  // Rapikan spasi berlebih hasil ekstraksi operator Tj/TJ.
  return out
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

int _skipEol(Uint8List data, int from) {
  var j = from;
  while (j < data.length && (data[j] == 13 || data[j] == 10 || data[j] == 32)) {
    j++;
  }
  return j;
}

int? _findEndstream(Uint8List data, int from) {
  final token = 'endstream'.codeUnits;
  outer:
  for (var i = from; i <= data.length - 9; i++) {
    for (var k = 0; k < 9; k++) {
      if (data[i + k] != token[k]) continue outer;
    }
    return i;
  }
  return null;
}

String? _tryInflate(List<int> chunk) {
  try {
    final codec = ZLibCodec();
    final out = codec.decode(chunk);
    return latin1.decode(out, allowInvalid: true);
  } catch (_) {
    // Bukan stream zlib (mungkin gambar DCTDecode/lainnya) — abaikan.
    return null;
  }
}

int _extractPdfTextOps(String stream, StringBuffer buf) {
  if (!stream.contains('Tj') && !stream.contains('TJ')) return 0;
  final re = RegExp(
    r'\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f\s]+>|T\*|Td|TD|BT|ET',
    multiLine: true,
  );
  var count = 0;
  for (final m in re.allMatches(stream)) {
    final token = m.group(0)!;
    if (token.startsWith('(')) {
      buf.write(_unescapePdfLiteral(token.substring(1, token.length - 1)));
      count++;
    } else if (token.startsWith('<')) {
      buf.write(_decodePdfHex(token.substring(1, token.length - 1)));
      count++;
    } else if (token == 'T*' || token == 'Td' || token == 'TD') {
      buf.writeln();
    } else if (token == 'ET') {
      buf.writeln();
    }
  }
  return count;
}

String _unescapePdfLiteral(String s) => s
    .replaceAll(r'\(', '(')
    .replaceAll(r'\)', ')')
    .replaceAll(r'\\', r'\')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\r', '')
    .replaceAll(r'\t', '\t');

String _decodePdfHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  final sb = StringBuffer();
  if (clean.length.isOdd) return '';
  // Heuristic: PDFStroke hex 2-digit = latin1; 4-digit = UTF-16BE.
  if (clean.length >= 4 && _looksUtf16(clean)) {
    for (var i = 0; i + 3 < clean.length; i += 4) {
      final cp = int.tryParse(clean.substring(i, i + 4), radix: 16);
      if (cp != null) sb.writeCharCode(cp);
    }
    return sb.toString();
  }
  for (var i = 0; i + 1 < clean.length; i += 2) {
    final b = int.tryParse(clean.substring(i, i + 2), radix: 16);
    if (b != null) sb.writeCharCode(b);
  }
  return sb.toString();
}

bool _looksUtf16(String hex) {
  // Pasangan pertama identik-nol tinggi (mis. `0041`) mengindikasikan UTF-16BE.
  for (var i = 0; i + 1 < hex.length && i < 8; i += 4) {
    final hi = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (hi == null) return false;
    if (hi != 0) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Office XML (DOCX/ODT/XLSX/PPTX) — pakai package:archive
// ---------------------------------------------------------------------------

String? _extractOfficeXml(
  List<int> bytes, {
  required RegExp entryPattern,
  required RegExp paragraphEnd,
}) {
  final zip = ZipDecoder().decodeBytes(bytes);
  for (final entry in zip) {
    if (entry.isFile && entryPattern.hasMatch(entry.name)) {
      final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
      return _xmlToText(xml, paragraphEnd: paragraphEnd);
    }
  }
  throw const FormatException('entry dokumen utama tidak ditemukan');
}

String _xmlToText(String xml, {required RegExp paragraphEnd}) {
  // Paragraf jadi newline; tag pemisah lain jadi spasi; sisanya buang.
  final withBreaks = xml.replaceAll(paragraphEnd, '\n');
  final stripped = withBreaks
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  return stripped
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
}

String? _extractXlsx(List<int> bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  for (final entry in zip) {
    if (entry.isFile && entry.name == 'xl/sharedStrings.xml') {
      final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
      // sharedStrings: satu <si> berisi satu nilai sel (bisa beberapa <t>).
      final items = <String>[];
      for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true)
          .allMatches(xml)) {
        final ts = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
            .allMatches(si.group(1)!)
            .map((t) => t.group(1) ?? '')
            .join();
        if (ts.isNotEmpty) items.add(ts);
      }
      if (items.isEmpty) return null;
      return items.join('\n');
    }
  }
  throw const FormatException('xl/sharedStrings.xml tidak ditemukan');
}

String? _extractPptx(List<int> bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final slides = <String>[];
  final names =
      zip.where((e) => e.isFile && RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(e.name)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  for (final entry in names) {
    final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
    final texts = RegExp(r'<a:t>(.*?)</a:t>', dotAll: true)
        .allMatches(xml)
        .map((m) => m.group(1) ?? '')
        .where((t) => t.isNotEmpty);
    if (texts.isNotEmpty) slides.add(texts.join('\n'));
  }
  if (slides.isEmpty) return null;
  return slides.join('\n\n--- slide berikutnya ---\n\n');
}
