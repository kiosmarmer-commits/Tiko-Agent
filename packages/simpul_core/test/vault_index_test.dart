import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote note(
  String path, {
  String title = '',
  Map<String, Object?> props = const {},
  List<String> tags = const [],
  List<(String, bool)> links = const [],
  List<(String, String)> chunks = const [],
}) {
  return IndexedNote(
    path: path,
    title: title.isEmpty ? path : title,
    mtimeNs: 0,
    sizeBytes: 0,
    contentHash: 'hash-$path',
    wordCount: 10,
    props: props,
    tags: tags,
    aliases: const [],
    links: [
      for (final (target, embed) in links)
        ParsedLink(
          target: target,
          anchor: '',
          alias: '',
          kind: 'wikilink',
          embed: embed,
          offset: 0,
        ),
    ],
    chunks: [
      for (final (headingPath, text) in chunks)
        NoteChunk(
          headingPath: headingPath,
          startChar: 0,
          endChar: text.length,
          text: text,
        ),
    ],
  );
}

Future<void> testIndex(VaultIndex index) async {
  await index.replaceAll([
    note(
      'catatan/alpha.md',
      title: 'Alpha',
      tags: ['riset', 'proyek/alpha'],
      props: {'status': 'aktif'},
      links: [('beta', false), ('hilang', false)],
      chunks: [('Pengantar', 'Alpha membahas jaringan saraf')],
    ),
    note(
      'catatan/beta.md',
      title: 'Beta',
      tags: ['riset'],
      links: [('alpha', false)],
      chunks: [('Latar', 'Beta melanjutkan pembahasan jaringan')],
    ),
    note(
      'jurnal/orphan.md',
      title: 'Orphan',
    ),
  ]);

  final termHits = await index.search('jaringan');
  expect(termHits.map((h) => h.path), contains('catatan/alpha.md'));
  expect(termHits.first.snippet, isNotEmpty);

  final titleHits = await index.search('Alpha');
  expect(titleHits.first.path, 'catatan/alpha.md');

  final phraseHits = await index.search('"jaringan saraf"');
  expect(phraseHits.map((h) => h.path), ['catatan/alpha.md']);

  final tagHits = await index.search('tag:riset');
  expect(tagHits.map((h) => h.path).toSet(), {'catatan/alpha.md', 'catatan/beta.md'});

  final subTagHits = await index.search('tag:proyek');
  expect(subTagHits.map((h) => h.path), ['catatan/alpha.md']);

  final pathHits = await index.search('path:jurnal');
  expect(pathHits.map((h) => h.path), ['jurnal/orphan.md']);

  final propHits = await index.search('prop:status=aktif');
  expect(propHits.map((h) => h.path), ['catatan/alpha.md']);

  final excluded = await index.search('jaringan -beta');
  expect(excluded.map((h) => h.path), ['catatan/alpha.md']);

  final backlinks = await index.backlinks('catatan/beta.md');
  expect(backlinks, ['catatan/alpha.md']);

  final health = await index.health();
  expect(health.noteCount, 3);
  expect(health.brokenLinks['hilang'], 1);
  expect(health.orphans, contains('jurnal/orphan.md'));

  await index.close();
}

Future<void> testIncremental(VaultIndex index) async {
  await index.replaceAll([
    note('satu.md', title: 'Satu', links: [('dua', false)], chunks: [('Isi', 'kata kunci pengukuran')]),
    note('dua.md', title: 'Dua'),
  ]);

  await index.upsert([
    note('dua.md', title: 'Dua Revisi', links: [('satu', false)], chunks: [('Isi', 'dua diperbarui')]),
    note('tiga.md', title: 'Tiga'),
  ]);

  final revised = await index.search('Dua Revisi');
  expect(revised.single.path, 'dua.md');
  final newBacklinks = await index.backlinks('satu.md');
  expect(newBacklinks, contains('dua.md'));

  await index.removePaths(['tiga.md']);
  final health = await index.health();
  expect(health.noteCount, 2);

  await index.close();
}

void main() {
  group('JsonVaultIndex', () {
    test('indexes, searches, backlinks, and reports health', () async {
      await testIndex(JsonVaultIndex('/tmp/simpul-test-index.json'));
    });

    test('persists and reloads across instances', () async {
      final path = '/tmp/simpul-test-persist.json';
      final writer = JsonVaultIndex(path);
      await writer.replaceAll([
        note('satu.md', title: 'Satu', chunks: [('Isi', 'kata kunci unik pengukuran')]),
      ]);
      await writer.close();
      expect(File(path).existsSync(), isTrue);

      final reader = JsonVaultIndex(path);
      final hits = await reader.search('pengukuran');
      expect(hits.single.path, 'satu.md');
      final health = await reader.health();
      expect(health.noteCount, 1);
      await reader.close();
    });
  });

  group('SqliteVaultIndex', () {
    test('behaves identically when sqlite3 is available', () async {
      final index = SqliteVaultIndex.tryOpen('/tmp/simpul-test-index.db');
      if (index == null) {
        markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
        return;
      }
      await testIndex(index);
    });

    test('incremental upsert and remove work when sqlite3 is available', () async {
      final index = SqliteVaultIndex.tryOpen('/tmp/simpul-test-incremental.db');
      if (index == null) {
        markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
        return;
      }
      await testIncremental(index);
    });
  });
}
