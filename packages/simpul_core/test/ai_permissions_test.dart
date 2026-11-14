import 'dart:convert';
import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-aiperms-test');
    vault = '${tmp.path}/vault';
    await Directory('$vault/.simpul').create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  void writeConfig(Map<String, Object?> config) {
    File('$vault/.simpul/ai-permissions.json')
        .writeAsStringSync(jsonEncode(config));
  }

  test('tanpa config: policy off, semua diizinkan', () {
    final policy = AiAccessPolicy.load(vault);
    expect(policy.isOff, isTrue);
    expect(policy.decide('apa/saja/catatan.md'), AiAccessDecision.allow);
  });

  test('alias bahasa Indonesia dan Inggris dikenali', () {
    writeConfig({
      'default': 'allow',
      'folders': {'rahasia': 'tolak', 'draft': 'tanya dulu'},
    });
    final policy = AiAccessPolicy.load(vault);
    expect(policy.decide('rahasia/kunci.md'), AiAccessDecision.deny);
    expect(policy.decide('draft/abc.md'), AiAccessDecision.ask);
    expect(policy.decide('umum/abc.md'), AiAccessDecision.allow);
  });

  test('status paling ketat menang antar lapisan', () {
    writeConfig({
      'default': 'izin',
      'folders': {'proyek': 'tanya'},
      'notes': {'proyek/kunci.md': 'tolak'},
      'tags': {'pribadi': 'tolak'},
    });
    final policy = AiAccessPolicy.load(vault);
    expect(policy.decide('proyek/lain.md'), AiAccessDecision.ask);
    expect(policy.decide('proyek/kunci.md'), AiAccessDecision.deny);
    expect(
      policy.decide('bebas/catatan.md', tags: {'pribadi/keluarga'}),
      AiAccessDecision.deny,
      reason: 'nested tag cocok dengan prefix aturan tag',
    );
    expect(
      policy.decide('bebas/catatan.md', tags: {'kerja'}),
      AiAccessDecision.allow,
    );
  });

  test('folder prefix terpanjang yang menentukan batas', () {
    writeConfig({
      'default': 'allow',
      'folders': {'a': 'deny', 'a/b': 'allow'},
    });
    final policy = AiAccessPolicy.load(vault);
    expect(policy.decide('a/b/c.md'), AiAccessDecision.allow);
    expect(policy.decide('a/lain.md'), AiAccessDecision.deny);
    expect(policy.decide('ab/c.md'), AiAccessDecision.allow,
        reason: 'batas folder adalah slash, bukan prefix mentah');
  });

  test('config rusak → FormatException; denyAll sebagai fallback', () {
    File('$vault/.simpul/ai-permissions.json')
        .writeAsStringSync('{bukan json');
    expect(() => AiAccessPolicy.load(vault), throwsFormatException);

    final denyAll = AiAccessPolicy.denyAll();
    expect(denyAll.decide('apa/saja.md'), AiAccessDecision.deny);
  });

  test('nilai status tidak dikenal → FormatException (fail-closed)', () {
    writeConfig({'default': 'mungkin'});
    expect(() => AiAccessPolicy.load(vault), throwsFormatException);
  });

  test('audit logger menulis JSONL dengan urutan terjaga', () {
    final audit = AiAuditLogger(vault);
    audit.log(tool: 'read_note', target: 'a.md', decision: AiAccessDecision.allow);
    audit.log(
      tool: 'read_note',
      target: 'b.md',
      decision: AiAccessDecision.deny,
      detail: {'reason': 'tolak'},
    );

    final lines = File('$vault/.simpul/ai-audit.jsonl')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(2));
    final first = jsonDecode(lines[0]) as Map<String, Object?>;
    final second = jsonDecode(lines[1]) as Map<String, Object?>;
    expect(first['tool'], 'read_note');
    expect(first['decision'], 'allow');
    expect(second['decision'], 'deny');
    expect((second['detail'] as Map<String, Object?>)['reason'], 'tolak');
    expect(DateTime.parse(first['ts'] as String), isNotNull);
  });

  test('tagsOf mengembalikan tag per path untuk kedua backend', () async {
    const note = IndexedNote(
      path: 'catatan/satu.md',
      title: 'Satu',
      mtimeNs: 0,
      sizeBytes: 4,
      contentHash: 'h1',
      wordCount: 1,
      props: {},
      tags: ['kerja', 'pribadi/keluarga'],
      aliases: [],
      links: [],
      chunks: [],
    );
    final index = JsonVaultIndex('$vault/.simpul/index.json');
    await index.replaceAll([note]);
    expect(
      await index.tagsOf({'catatan/satu.md', 'tidak/ada.md'}),
      {
        'catatan/satu.md': ['kerja', 'pribadi/keluarga'],
      },
    );
    await index.close();

    final sqlite = SqliteVaultIndex.tryOpen('$vault/.simpul/index.db');
    if (sqlite == null) {
      markTestSkipped('libsqlite3 tidak tersedia di lingkungan ini');
      return;
    }
    try {
      await sqlite.replaceAll([note]);
      expect(
        await sqlite.tagsOf({'catatan/satu.md'}),
        {
          'catatan/satu.md': ['kerja', 'pribadi/keluarga'],
        },
      );
    } finally {
      await sqlite.close();
    }
  });
}
