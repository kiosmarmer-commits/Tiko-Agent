import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// A.2/A.3 — ingest lampiran penuh: ekstraksi zip aman, ekstraksi teks
/// dokumen (PDF/DOCX), budget teks 64 KiB/128 KiB, dan fail-closed.
/// Semua biner dibuat in-test (ZipEncoder / ZLibCodec) — tanpa aset statis.
void main() {
  late Directory tmp;
  late String uploadsDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_ingest_');
    uploadsDir = '${tmp.path}/uploads/sesi-1';
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  Attachment doc(String name, String content, [String mime = 'text/plain']) =>
      Attachment(type: 'document', urlOrBytes: bytes(content), mime: mime,
          name: name);

  Uint8List makeZip(Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach((name, content) {
      archive.addFile(ArchiveFile(name, content.length, content));
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  test('lampiran teks sama kontraknya dengan ekspansi C2 lama', () {
    final r = ingestAttachments(
      [doc('laporan.md', '= Ringkasan =\npendapatan naik')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.text, contains('[lampiran: laporan.md (text/plain'));
    expect(r.text, contains('= Ringkasan ='));
    expect(r.text, contains('[/lampiran: laporan.md]'));
    expect(r.text, contains('[akhir lampiran]'));
    expect(r.stats.single['status'], 'ok');
  });

  test('zip diekstrak aman ke folder uploads + listing teratas', () {
    final zip = makeZip({
      'src/main.dart': utf8.encode('void main() {}'),
      'README.md': utf8.encode('# proyek cetak'),
      'src/lib/util.dart': utf8.encode('final x = 1;'),
    });
    final r = ingestAttachments(
      [Attachment(type: 'document', urlOrBytes: zip,
          mime: 'application/zip', name: 'proyek.zip')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'ok');
    expect(r.stats.single['entries'], 3);
    final extractedDir = r.stats.single['extracted_dir'] as String;
    expect(File('$extractedDir/src/main.dart').existsSync(), isTrue);
    expect(File('$extractedDir/src/main.dart').readAsStringSync(),
        contains('void main() {}'));
    expect(r.text, contains('diekstrak ke "$extractedDir"'));
    expect(r.text, contains('README.md'));
    expect(r.text, contains('list_dir/grep/read_file'));
  });

  test('zip tanpa mime tetap terdeteksi dari ekstensi .zip', () {
    final zip = makeZip({'a.txt': utf8.encode('isi')});
    final r = ingestAttachments(
      [Attachment(type: 'document', urlOrBytes: zip, name: 'arsip.zip')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'ok');
    expect(r.stats.single['entries'], 1);
  });

  test('zip yang rusak total → status error jujur, tidak throw', () {
    final r = ingestAttachments(
      [Attachment(type: 'document', urlOrBytes: bytes('bukan zip'),
          mime: 'application/zip', name: 'rusak.zip')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'error');
    expect(r.text, contains('rusak.zip'));
    expect(r.text, contains('[akhir lampiran]'));
  });

  test('entry traversal (`..`) dan absolut ditolak, sisanya diekstrak', () {
    final zip = makeZip({
      'baik.txt': utf8.encode('ok'),
      '../escape.txt': utf8.encode('boom'),
      'sub/../naik.txt': utf8.encode('juga ditolak'),
    });
    final r = ingestAttachments(
      [Attachment(type: 'document', urlOrBytes: zip,
          mime: 'application/zip', name: 'evil.zip')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'ok');
    expect(r.stats.single['entries'], 1);
    expect(r.text, contains('[DITOLAK:'));
    final files = Directory(uploadsDir)
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(files.any((f) => f.endsWith('escape.txt')), isFalse,
        reason: 'traversal tidak boleh keluar folder tujuan');
    expect(files.any((f) => f.endsWith('baik.txt')), isTrue);
  });

  test('dedupe nama file yang disimpan dengan nama sama', () {
    // PDF palsu tidak menghasilkan teks → jatuh ke cabang simpan mentah
    // dua kali; file kedua harus mendapat nama unik a(2).pdf.
    final fakePdf = bytes('%PDF-1.4\nbukan pdf valid\n');
    final r = ingestAttachments(
      [
        Attachment(type: 'document', urlOrBytes: fakePdf,
            mime: 'application/pdf', name: 'a.pdf'),
        Attachment(type: 'document',
            urlOrBytes: Uint8List.fromList([...fakePdf, 0x30]),
            mime: 'application/pdf', name: 'a.pdf'),
      ],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats[0]['path'] as String, endsWith('a.pdf'));
    expect(r.stats[1]['path'] as String, endsWith('a(2).pdf'));
    expect(File(r.stats[1]['path'] as String).existsSync(), isTrue);
  });

  test('ukuran per-file teks dipotong di 64 KiB dengan penanda jujur', () {
    final r = ingestAttachments(
      [doc('big.txt', 'x' * (100 * 1024))],
      uploadsDirPath: uploadsDir,
    );
    expect(r.text, contains('dipotong'));
    expect(r.stats.single['bytes'], lessThanOrEqualTo(128 * 1024));
  });

  test('budget total 128 KiB memotong file berikutnya', () {
    final r = ingestAttachments(
      [doc('a.txt', 'a' * 100 * 1024), doc('b.txt', 'b' * 60 * 1024)],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats[0]['bytes'], lessThanOrEqualTo(128 * 1024));
    expect(r.stats[1]['status'], 'ok');
    expect(r.text, contains('dipotong'));
  });

  test('bukan Uint8List → status error jujur, pesan tetap terkirim', () {
    final r = ingestAttachments(
      [const Attachment(type: 'image', urlOrBytes: 'http://x/img.png',
          mime: 'image/png', name: 'img.png')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'error');
    expect(r.text, contains('[lampiran img.png'));
    expect(r.text, contains('[akhir lampiran]'));
  });

  test('gambar biner: hanya metadata + mentah disimpan ke uploads', () {
    final fakePng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]);
    final r = ingestAttachments(
      [Attachment(type: 'image', urlOrBytes: fakePng, mime: 'image/png',
          name: 'shot.png')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'stored');
    final storedPath = r.stats.single['path'] as String;
    expect(File(storedPath).existsSync(), isTrue);
    expect(File(storedPath).readAsBytesSync(), fakePng);
    expect(r.text, contains(' tersimpan di "$storedPath"'));
    expect(r.text, contains('vision'));
  });

  test('nama lampiran berbahaya disanitasi, ingest tidak pernah throw', () {
    final r = ingestAttachments(
      [doc('../jail/naughty.txt', 'x')],
      uploadsDirPath: uploadsDir,
    );
    expect(r.stats.single['status'], 'ok');
    expect(r.stats.single['name'] as String, isNot(contains('/')));
    expect(r.stats.single['name'] as String, isNot(contains('..')));
  });

  test('daftar lampiran kosong tidak memberi blok', () {
    final r = ingestAttachments(const [], uploadsDirPath: uploadsDir);
    expect(r.text, isEmpty);
    expect(r.stats, isEmpty);
  });

  test('sanitizeSessionDirName aman untuk id sesi gateway', () {
    expect(sanitizeSessionDirName('mcp:foo/bar'), isNot(contains(':')));
    expect(sanitizeSessionDirName('mcp:foo/bar'), isNot(contains('/')));
    expect(sanitizeSessionDirName('..'), 'default');
    expect(sanitizeSessionDirName('sesi-1'), 'sesi-1');
  });
}
