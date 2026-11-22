import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

/// A.2 — tool `unzip_archive`: ekstraksi aman di dalam workspace,
/// anti path-traversal, anti zip bomb, fail-closed.
void main() {
  late Directory tmp;
  late Session session;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_unzip_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() => ToolContext(session: session, workspacePath: tmp.path);

  UnzipArchiveTool tool() => UnzipArchiveTool(workspaceRoot: tmp.path);

  Uint8List makeZip(Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach((name, content) {
      archive.addFile(ArchiveFile(name, content.length, content));
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  test('ekstraksi default ke folder <nama-arsip>/ dan isi cocok', () async {
    File('${tmp.path}/arsip.zip').writeAsBytesSync(makeZip({
      'src/main.dart': utf8.encode('void main() {}'),
      'README.md': utf8.encode('# halo'),
    }));
    final r = await tool().run({'path': 'arsip.zip'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('Diekstrak 2/2 entry'));
    expect(File('${tmp.path}/arsip/src/main.dart').readAsStringSync(),
        contains('void main() {}'));
    expect(r.content, contains('README.md'));
  });

  test('dest override relatif workspace dipakai', () async {
    File('${tmp.path}/arsip.zip').writeAsBytesSync(makeZip({
      'a.txt': utf8.encode('isi'),
    }));
    final r = await tool().run({'path': 'arsip.zip', 'dest': 'hasil'},
        ctx());
    expect(r.isError, isFalse);
    expect(File('${tmp.path}/hasil/a.txt').readAsStringSync(), 'isi');
  });

  test('path kosong dan path di luar workspace ditolak', () async {
    final rEmpty = await tool().run({'path': ''}, ctx());
    expect(rEmpty.isError, isTrue);
    expect(rEmpty.content, contains('path kosong'));

    final rOut = await tool().run({'path': '../luar.zip'}, ctx());
    expect(rOut.isError, isTrue);
    expect(rOut.content, contains('di luar workspace'));
  });

  test('file tidak ada → error jujur', () async {
    final r = await tool().run({'path': 'tidakada.zip'}, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('tidak ditemukan'));
  });

  test('entry traversal ditolak, entry normal tetap diekstrak', () async {
    File('${tmp.path}/evil.zip').writeAsBytesSync(makeZip({
      'baik.txt': utf8.encode('ok'),
      '../escape.txt': utf8.encode('boom'),
    }));
    final r = await tool().run({'path': 'evil.zip'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('[DITOLAK: 1 entry'));
    expect(File('${tmp.path}/baik.txt').existsSync(), isFalse,
        reason: 'default dest adalah folder arsip, bukan root');
    expect(
      Directory('${tmp.path}/evil').listSync(recursive: true)
          .whereType<File>()
          .any((f) => f.path.endsWith('escape.txt')),
      isFalse,
    );
  });

  test('arsip kosong → pesan jujur tanpa error', () async {
    File('${tmp.path}/kosong.zip').writeAsBytesSync(makeZip({}));
    final r = await tool().run({'path': 'kosong.zip'}, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('Arsip kosong'));
  });

  test('bukan zip valid → error fail-closed, tanpa throw', () async {
    File('${tmp.path}/rusak.zip')
        .writeAsBytesSync(Uint8List.fromList(utf8.encode('bukan zip')));
    final r = await tool().run({'path': 'rusak.zip'}, ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('gagal mengekstrak'));
  });

  test('dest juga divalidasi terhadap workspace root', () async {
    File('${tmp.path}/arsip.zip').writeAsBytesSync(makeZip({
      'a.txt': utf8.encode('isi'),
    }));
    final r = await tool().run({'path': 'arsip.zip', 'dest': '../luar'},
        ctx());
    expect(r.isError, isTrue);
    expect(r.content, contains('dest di luar workspace'));
  });

  test('spec: nama, risk medium, schema wajib path', () {
    final spec = tool().spec;
    expect(spec.name, 'unzip_archive');
    expect(spec.risk, 'medium');
    expect((spec.inputSchema['required'] as List).contains('path'), isTrue);
  });
}
