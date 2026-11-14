import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-delta-test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> makeVault(
    String name,
    Map<String, String> notes,
  ) async {
    final vault = p.join(tmp.path, name);
    await Directory(vault).create(recursive: true);
    for (final entry in notes.entries) {
      final file = File(p.join(vault, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    return vault;
  }

  test('dua arah: perubahan di kedua perangkat konvergen', () async {
    final a = await makeVault('a', {
      'notes/alpha.md': '# Alpha\nDari A',
      'notes/beta.md': '# Beta\nDari A',
    });
    final b = await makeVault('b', {
      'notes/alpha.md': '# Alpha\nDari A',
      'notes/gamma.md': '# Gamma\nDari B',
    });
    await DeltaSync.initJournal(a, deviceId: 'device-a');
    await DeltaSync.initJournal(b, deviceId: 'device-b');

    final deltaA = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'a-to-b.simpuldelta'),
    );
    expect(deltaA.fileCount, 1, reason: 'hanya beta yang belum ada di B');
    final r1 = await DeltaSync.importDelta(b, deltaA.path);
    expect(r1.applied, ['notes/beta.md']);
    expect(r1.conflicts, isEmpty);

    final deltaB = await DeltaSync.exportDelta(
      b,
      peerJournalFile: DeltaSync.journalPath(a),
      outPath: p.join(tmp.path, 'b-to-a.simpuldelta'),
    );
    final r2 = await DeltaSync.importDelta(a, deltaB.path);
    expect(r2.applied, ['notes/gamma.md']);

    expect(File(p.join(a, 'notes/gamma.md')).readAsStringSync(),
        '# Gamma\nDari B');
    expect(File(p.join(b, 'notes/beta.md')).readAsStringSync(), '# Beta\nDari A');
  });

  test('delta kedua kosong setelah sinkron (inkremental)', () async {
    final a = await makeVault('a2', {'x.md': 'satu'});
    final b = await makeVault('b2', {});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');
    final d1 = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'd1.delta'),
    );
    expect(d1.fileCount, 1);
    await DeltaSync.importDelta(b, d1.path);
    final d2 = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'd2.delta'),
    );
    expect(d2.fileCount, 0);
  });

  test('konflik dua sisi: keep-both menulis file conflict', () async {
    final a = await makeVault('a3', {'n.md': 'versi A'});
    final b = await makeVault('b3', {'n.md': 'versi A'});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');

    await File(p.join(a, 'n.md')).writeAsString('versi A2');
    await File(p.join(b, 'n.md')).writeAsString('versi B2');
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');

    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'conflict.delta'),
    );
    final result = await DeltaSync.importDelta(b, delta.path);
    expect(result.conflicts, isEmpty);
    expect(result.applied, hasLength(1));
    final written = result.applied.single;
    expect(written, startsWith('n.conflict-a-'));
    expect(File(p.join(b, 'n.md')).readAsStringSync(), 'versi B2',
        reason: 'file asli B tidak tertimpa');
    expect(File(p.join(b, written)).readAsStringSync(), 'versi A2');
  });

  test('konflik strategi newest dan ours/theirs', () async {
    final a = await makeVault('a4', {'n.md': 'versi A'});
    final b = await makeVault('b4', {'n.md': 'versi A'});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');
    await File(p.join(a, 'n.md')).writeAsString('versi A2');
    await File(p.join(b, 'n.md')).writeAsString('versi B2');
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');
    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'c.delta'),
    );

    final theirs = await DeltaSync.importDelta(
      b,
      delta.path,
      strategy: ConflictStrategy.theirs,
    );
    expect(theirs.applied, ['n.md']);
    expect(File(p.join(b, 'n.md')).readAsStringSync(), 'versi A2');

    final c = await makeVault('c4', {'n.md': 'versi A'});
    await DeltaSync.initJournal(c, deviceId: 'c');
    await File(p.join(c, 'n.md')).writeAsString('versi C2');
    await DeltaSync.initJournal(c, deviceId: 'c');
    final ours = await DeltaSync.importDelta(
      c,
      delta.path,
      strategy: ConflictStrategy.ours,
    );
    expect(ours.conflicts, ['n.md']);
    expect(File(p.join(c, 'n.md')).readAsStringSync(), 'versi C2');
  });

  test('tombstone: hapus di A terpropagasi ke B', () async {
    final a = await makeVault('a5', {'gone.md': 'hapus saya', 'stay.md': 'tetap'});
    final b = await makeVault('b5', {'gone.md': 'hapus saya', 'stay.md': 'tetap'});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');

    await File(p.join(a, 'gone.md')).delete();
    await DeltaSync.initJournal(a, deviceId: 'a');
    final journal = await DeltaSync.readJournal(a);
    final tomb = (journal['tombstones'] as Map)['gone.md'] as Map;
    expect(tomb['deleted'], true);
    expect(tomb['hash'], sha256.convert(utf8.encode('hapus saya')).toString());

    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'tomb.delta'),
    );
    expect(delta.tombstoneCount, 1);
    final result = await DeltaSync.importDelta(b, delta.path);
    expect(result.tombstonesApplied, ['gone.md']);
    expect(File(p.join(b, 'gone.md')).existsSync(), isFalse);
    expect(File(p.join(b, 'stay.md')).existsSync(), isTrue);
  });

  test('delta terenkripsi: password salah dan tamper ditolak', () async {
    final a = await makeVault('a6', {'s.md': 'rahasia'});
    final b = await makeVault('b6', {});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');
    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      password: 'benar',
      outPath: p.join(tmp.path, 'enc.delta'),
    );
    expect(
      () => DeltaSync.importDelta(b, delta.path, password: 'salah'),
      throwsA(isA<VaultCryptoException>()),
    );

    final bytes = File(delta.path).readAsBytesSync();
    bytes[bytes.length - 1] ^= 0xFF;
    await File(delta.path).writeAsBytes(bytes);
    expect(
      () => DeltaSync.importDelta(b, delta.path, password: 'benar'),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('delta terenkripsi roundtrip dengan password benar', () async {
    final a = await makeVault('a7', {'s.md': 'rahasia'});
    final b = await makeVault('b7', {});
    await DeltaSync.initJournal(a, deviceId: 'a');
    await DeltaSync.initJournal(b, deviceId: 'b');
    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      password: 'benar',
      outPath: p.join(tmp.path, 'enc2.delta'),
    );
    final result = await DeltaSync.importDelta(b, delta.path, password: 'benar');
    expect(result.applied, ['s.md']);
    expect(File(p.join(b, 's.md')).readAsStringSync(), 'rahasia');
  });

  test('magic/versi asing dan traversal ditolak', () async {
    final b = await makeVault('b8', {});
    await DeltaSync.initJournal(b, deviceId: 'b');
    final bad = p.join(tmp.path, 'bad.delta');
    await File(bad).writeAsBytes(utf8.encode('NOTADELTA!........'));
    expect(
      () => DeltaSync.importDelta(b, bad),
      throwsA(isA<DeltaSyncException>()),
    );

    final a = await makeVault('a8', {'ok.md': 'isi'});
    await DeltaSync.initJournal(a, deviceId: 'a');
    final journal = await DeltaSync.readJournal(a);
    (journal['files'] as Map)['../evil.md'] = {'hash': 'x', 'size': 3, 'rev': 0};
    await File(p.join(a, DeltaSync.journalPath(a))).writeAsString(jsonEncode(journal));
    final delta = await DeltaSync.exportDelta(
      a,
      peerJournalFile: DeltaSync.journalPath(b),
      outPath: p.join(tmp.path, 'evil.delta'),
    );
    expect(
      () => DeltaSync.importDelta(b, delta.path),
      throwsA(isA<DeltaSyncException>()),
    );
  });

  test('vault tanpa journal ditolak saat export/status', () async {
    final a = await makeVault('a9', {'x.md': 'ya'});
    expect(
      () => DeltaSync.status(a),
      throwsA(isA<DeltaSyncException>()),
    );
    expect(
      () => DeltaSync.exportDelta(
        a,
        peerJournalFile: p.join(tmp.path, 'none.json'),
      ),
      throwsA(isA<DeltaSyncException>()),
    );
  });
}
