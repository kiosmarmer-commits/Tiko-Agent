import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// A.3 — ekstraktor teks dokumen best-effort. Semua fixture dibuat
/// in-test (ZipEncoder / ZLibCodec) — tanpa aset biner statis.
void main() {
  Uint8List makeZip(Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach((name, content) {
      archive.addFile(ArchiveFile(name, content.length, content));
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// PDF minimal: header %PDF + satu stream ZLib berisi operator teks.
  Uint8List makePdf(String text) {
    final ops = 'BT /F1 12 Tf ($text) Tj ET';
    final compressed =
        Uint8List.fromList(ZLibCodec().encode(ops.codeUnits));
    final head = utf8.encode('%PDF-1.4\n1 0 obj << /Filter /FlateDecode '
        '/Length ${compressed.length} >>\nstream\n');
    final tail = utf8.encode('\nendstream\nendobj\n%%EOF\n');
    final out = BytesBuilder()
      ..add(head)
      ..add(compressed)
      ..add(tail);
    return out.toBytes();
  }

  Uint8List pdfWithOps(String ops) {
    final compressed =
        Uint8List.fromList(ZLibCodec().encode(ops.codeUnits));
    final body = BytesBuilder()
      ..add(utf8.encode('%PDF-1.4\nstream\n'))
      ..add(compressed)
      ..add(utf8.encode('\nendstream\n'));
    return body.toBytes();
  }

  group('PDF', () {
    test('stream FlateDecode berisi operator Tj diekstrak', () {
      final r = extractDocumentText(
          name: 'laporan.pdf', bytes: makePdf('Halo dari PDF'));
      expect(r.text, 'Halo dari PDF');
      expect(r.note, contains('ok'));
    });

    test('literal escape \\( \\) didekod', () {
      final r = extractDocumentText(
          name: 'a.pdf', bytes: makePdf(r'x \(y\) z'));
      expect(r.text, 'x (y) z');
    });

    test('operator Td menghasilkan baris baru', () {
      final r = extractDocumentText(
          name: 'a.pdf',
          bytes: pdfWithOps(
              'BT /F1 12 Tf (baris satu) Tj 0 20 Td (baris dua) Tj ET'));
      expect(r.text, 'baris satu\nbaris dua');
    });

    test('hex string <48656C6C6F> diekstrak sebagai latin1', () {
      final r = extractDocumentText(
          name: 'a.pdf',
          bytes: pdfWithOps('BT /F1 12 Tf <48656C6C6F> Tj ET'));
      expect(r.text, 'Hello');
    });

    test('tanpa tanda %PDF → fail-closed note, tanpa throw', () {
      final r = extractDocumentText(
          name: 'a.pdf', bytes: utf8.encode('bukan pdf'));
      expect(r.text, isNull);
      expect(r.note, isNotEmpty);
    });

    test('PDF tanpa stream teks → text null dengan note jujur', () {
      final r = extractDocumentText(
          name: 'kosong.pdf',
          bytes: utf8.encode('%PDF-1.4\ntanpa stream\n%%EOF\n'));
      expect(r.text, isNull);
    });
  });

  group('Office XML', () {
    test('DOCX: word/document.xml diekstrak per paragraf', () {
      final docx = makeZip({
        '[Content_Types].xml': utf8.encode('<Types/>'),
        'word/document.xml': utf8.encode(
          '<w:document><w:body>'
          '<w:p><w:r><w:t>Paragraf pertama</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Paragraf kedua</w:t></w:r></w:p>'
          '</w:body></w:document>',
        ),
      });
      final r = extractDocumentText(
          name: 'dok.docx',
          mime:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          bytes: docx);
      expect(r.text, 'Paragraf pertama\nParagraf kedua');
      expect(r.note, contains('DOCX'));
    });

    test('ODT: content.xml dipakai', () {
      final odt = makeZip({
        'content.xml': utf8.encode(
            '<office:text><text:p>Satu</text:p><text:p>Dua</text:p></office:text>'),
      });
      final r = extractDocumentText(name: 'cat.odt', bytes: odt);
      expect(r.text, 'Satu\nDua');
    });

    test('XLSX: xl/sharedStrings.xml dipakai', () {
      final xlsx = makeZip({
        'xl/sharedStrings.xml': utf8.encode(
            '<sst><si><t>Total</t></si><si><t>Rp 1.000</t></si></sst>'),
      });
      final r = extractDocumentText(name: 'data.xlsx', bytes: xlsx);
      expect(r.text, 'Total\nRp 1.000');
    });

    test('PPTX: slide diurutkan dan dipisah penanda slide', () {
      final pptx = makeZip({
        'ppt/slides/slide2.xml':
            utf8.encode('<p:sp><a:t>Slide dua</a:t></p:sp>'),
        'ppt/slides/slide1.xml':
            utf8.encode('<p:sp><a:t>Slide satu</a:t></p:sp>'),
      });
      final r = extractDocumentText(name: 'deck.pptx', bytes: pptx);
      expect(r.text, contains('Slide satu'));
      expect(r.text!.indexOf('Slide satu'),
          lessThan(r.text!.indexOf('Slide dua')));
      expect(r.text, contains('slide berikutnya'));
    });

    test('zip dokumen tanpa entry utama → fail-closed', () {
      final zip = makeZip({'acak.txt': utf8.encode('halo')});
      final r = extractDocumentText(name: 'dok.docx', bytes: zip);
      expect(r.text, isNull);
      expect(r.note, isNotEmpty);
    });
  });

  group('passthrough & fail-closed', () {
    test('text/plain didekode utf8 langsung', () {
      final r = extractDocumentText(
          name: 'catatan.txt', bytes: utf8.encode('isi catatan'));
      expect(r.text, 'isi catatan');
    });

    test('text/html tidak diproses sebagai teks (markup jangan bocor)', () {
      final r = extractDocumentText(
          name: 'h.html',
          mime: 'text/html',
          bytes: utf8.encode('<html><body>halo</body></html>'));
      expect(r.text, isNull);
    });

    test('tipe biner asing → note tidak didukung', () {
      final r = extractDocumentText(
          name: 'song.mp3',
          mime: 'audio/mpeg',
          bytes: Uint8List.fromList([1, 2, 3, 4]));
      expect(r.text, isNull);
      expect(r.note, contains('tidak didukung'));
    });

    test('maxChars memotong dengan penanda jujur', () {
      final r = extractDocumentText(
          name: 'besar.txt', bytes: utf8.encode('x' * 5000), maxChars: 100);
      expect(r.text, contains('[dipotong: 5000 total karakter'));
      expect(r.text!.startsWith('x' * 100), isTrue);
      expect(r.note, contains('dipotong'));
    });

    test('bytes kosong → tidak ada teks, tanpa throw', () {
      final r = extractDocumentText(name: 'k.docx', bytes: const <int>[]);
      expect(r.text, isNull);
      expect(r.note, isNotEmpty);
    });
  });
}
