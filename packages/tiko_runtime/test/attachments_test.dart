import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// C2 Chat-UX: ekspansi attachment ke blok konteks teks — file teks dibaca
/// bounded, gambar/biner hanya metadata jujur, tidak pernah throw.
void main() {
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  Attachment doc(String name, String content, [String mime = 'text/plain']) =>
      Attachment(
        type: 'document',
        urlOrBytes: bytes(content),
        mime: mime,
        name: name,
      );

  test('lampiran teks dekode utf8 dan dibungkus penanda [lampiran:]', () {
    final r = expandAttachments([
      doc('laporan.md', '= Ringkasan =\npendapatan naik'),
    ]);
    expect(r.text, contains('[lampiran: laporan.md (text/plain'));
    expect(r.text, contains('= Ringkasan ='));
    expect(r.text, contains('[/lampiran: laporan.md]'));
    expect(r.text, contains('[akhir lampiran]'));
    expect(r.stats.single['status'], 'ok');
  });

  test('file json/application subset diperlakukan sebagai teks', () {
    final r = expandAttachments([
      doc('cfg.json', '{"a": 1}', 'application/json'),
    ]);
    expect(r.text, contains('\"a\"'));
    expect(r.stats.single['status'], 'ok');
  });

  test('ukuran per file dipotong pada 64 KiB dengan penanda jujur', () {
    final big = doc('big.txt', 'x' * (100 * 1024));
    final r = expandAttachments([big]);
    expect(r.text, contains('dipotong'));
    expect(r.stats.single['bytes'], lessThanOrEqualTo(128 * 1024));
  });

  test('budget total 128 KiB mengurangi file berikutnya', () {
    // a terpotong ke 64 KiB (sisa budget 64 KiB), b 60 KiB muat, sehingga
    // sisa budget tinggal 4 KiB dan c terpotong di bawah cap per-file.
    final r = expandAttachments([
      doc('a.txt', 'a' * 100 * 1024),
      doc('b.txt', 'b' * 60 * 1024),
      doc('c.txt', 'c' * 60 * 1024),
    ]);
    expect(r.stats[0]['bytes'], 64 * 1024);
    expect(r.stats[1]['bytes'], 60 * 1024);
    expect(r.stats[1]['status'], 'ok');
    expect(r.stats[2]['bytes'], 4 * 1024);
    expect(r.text, contains('dipotong'));
  });

  test('gambar menghasilkan metadata jujur, bukan isi karangan', () {
    final r = expandAttachments([
      Attachment(
        type: 'image',
        urlOrBytes: Uint8List.fromList([1, 2, 3, 4]),
        mime: 'image/png',
        name: 'snap.png',
      ),
    ]);
    expect(r.text, contains('tidak dapat dibaca sebagai teks'));
    expect(r.text, contains('image/png'));
    expect(r.text, contains('snap.png'));
    expect(r.text, contains('checksum fnv1a:'));
    expect(r.stats.single['status'], 'metadata');
  });

  test('data bukan byte → penanda error inline, tidak throw', () {
    final r = expandAttachments([
      Attachment(type: 'document', urlOrBytes: 'bukan-bytes', mime: 'text/plain', name: 'a.txt'),
    ]);
    expect(r.text, contains('bentuk data tidak dapat dibaca'));
    expect(r.stats.single['status'], 'error');
  });

  test('daftar kosong menghasilkan blok kosong', () {
    final r = expandAttachments(const []);
    expect(r.text, isEmpty);
    expect(r.stats, isEmpty);
  });

  test('attachmentMimeIsText: text/* dan subset application', () {
    expect(attachmentMimeIsText('text/plain'), isTrue);
    expect(attachmentMimeIsText('application/json'), isTrue);
    expect(attachmentMimeIsText('application/x-yaml'), isTrue);
    expect(attachmentMimeIsText('image/png'), isFalse);
    expect(attachmentMimeIsText(null), isFalse);
    expect(attachmentMimeIsText(''), isFalse);
  });

  test('decodeAttachmentBase64: padding kurang dinormalisasi, invalid gagal', () {
    final decoded = decodeAttachmentBase64('aGFsbw');
    expect(utf8.decode(decoded), 'halo');
    expect(
      () => decodeAttachmentBase64('!!!!!'),
      throwsFormatException,
    );
  });
}
