import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// A.1 — Project context file: prioritas kandidat, truncation jujur 12k,
/// dan fail-closed (file tak terbaca / tidak ada → null, tanpa throw).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tiko_ctx_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('TIKO.md prioritas tertinggi di atas kandidat lain', () {
    File('${tmp.path}/AGENTS.md').writeAsStringSync('agents panduan');
    File('${tmp.path}/TIKO.md').writeAsStringSync('tiko panduan');
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r, isNotNull);
    expect(r!.fileName, 'TIKO.md');
    expect(r.content, 'tiko panduan');
    expect(r.truncated, isFalse);
  });

  test('fallback AGENTS.md bila TIKO.md tidak ada', () {
    File('${tmp.path}/AGENTS.md').writeAsStringSync('agents panduan');
    File('${tmp.path}/GEMINI.md').writeAsStringSync('gemini panduan');
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r!.fileName, 'AGENTS.md');
  });

  test('urutan penuh: TIKO.md > AGENTS.md > CLAUDE.md > GEMINI.md', () {
    File('${tmp.path}/CLAUDE.md').writeAsStringSync('claude');
    File('${tmp.path}/GEMINI.md').writeAsStringSync('gemini');
    expect(
      resolveProjectContextFile(workspaceRoot: tmp.path)!.fileName,
      'CLAUDE.md',
    );
  });

  test('file kosong / whitespace dilewati, kandidat berikutnya dipakai', () {
    File('${tmp.path}/TIKO.md').writeAsStringSync('   \n  ');
    File('${tmp.path}/AGENTS.md').writeAsStringSync('agents panduan');
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r!.fileName, 'AGENTS.md');
  });

  test('tidak ada kandidat → null tanpa throw', () {
    expect(resolveProjectContextFile(workspaceRoot: tmp.path), isNull);
  });

  test('kandidat berbentuk folder (baca gagal) dilewati fail-closed', () {
    // File probe existsSync() == true untuk directory; readAsStringSync
    // melempar — harus ditangkap dan lanjut ke kandidat berikutnya.
    Directory('${tmp.path}/TIKO.md').createSync();
    File('${tmp.path}/GEMINI.md').writeAsStringSync('gemini panduan');
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r!.fileName, 'GEMINI.md');
  });

  test('truncation 12.000 char dengan penanda truncated', () {
    File('${tmp.path}/TIKO.md').writeAsStringSync('x' * 15000);
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r!.truncated, isTrue);
    expect(r.content.length, kProjectContextMaxChars);
    expect(kProjectContextMaxChars, 12000);
  });

  test('file lebih pendek dari limit tidak diubah', () {
    File('${tmp.path}/TIKO.md').writeAsStringSync('x' * 5000);
    final r = resolveProjectContextFile(workspaceRoot: tmp.path);
    expect(r!.truncated, isFalse);
    expect(r.content.length, 5000);
  });

  test('custom candidates: kandidat pertama yang ada dipilih', () {
    File('${tmp.path}/README.md').writeAsStringSync('readme panduan');
    final r = resolveProjectContextFile(
      workspaceRoot: tmp.path,
      candidates: ['MISSING.md', 'README.md'],
      maxChars: 100,
    );
    expect(r!.fileName, 'README.md');
  });
}
