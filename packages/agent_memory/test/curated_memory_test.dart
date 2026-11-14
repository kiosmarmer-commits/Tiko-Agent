import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

Future<CuratedMemoryStore> _store(Directory dir, {int budget = 3575}) {
  final store = CuratedMemoryStore(dataDir: dir.path, charBudget: budget);
  return store.load().then((_) => store);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('curated_mem_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('extract mengurai operasi satu baris dan membersihkan balasan', () {
    const reply = 'Saya simpan fakta berikut.\n'
        '```memory-ops\n'
        'ADD MEMORY: deploy pakai port 5433\n'
        'ADD USER: pengguna suka jawaban ringkas\n'
        'REPLACE MEMORY: port 5432 => port 5433\n'
        'REMOVE USER: preferensi lama\n'
        'baris tak valid diabaikan\n'
        '```\n'
        'Selesai.';
    final report = CuratedMemoryOps.extract(reply);
    expect(report.hasBlock, isTrue);
    expect(report.cleanedReply, 'Saya simpan fakta berikut.\n\nSelesai.');
    final ops = CuratedMemoryOps.extract(reply);
    expect(ops.cleanedReply, isNotNull);
  });

  test('apply: add/replace/remove pada kedua file', () async {
    final store = await _store(tmp);
    final report = CuratedMemoryOps.extract('x\n${CuratedMemoryOps.encode([
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.add,
          file: CuratedMemoryFile.memory,
          text: 'deploy pakai port 5433'),
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.add,
          file: CuratedMemoryFile.user,
          text: 'suka jawaban ringkas'),
    ])}\n');
    store.apply(report);
    expect(store.memoryText, 'deploy pakai port 5433');
    expect(store.userText, 'suka jawaban ringkas');

    final rep2 = CuratedMemoryOps.extract(CuratedMemoryOps.encode([
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.replace,
          file: CuratedMemoryFile.memory,
          find: '5433',
          text: '5434'),
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.remove,
          file: CuratedMemoryFile.user,
          find: 'suka jawaban ringkas'),
    ]));
    store.apply(rep2);
    expect(store.memoryText, 'deploy pakai port 5434');
    expect(store.userText, isEmpty);
  });

  test('anggaran karakter menolak ADD berlebih, konten lama utuh', () async {
    final store = await _store(tmp, budget: 50);
    store.memoryText = 'a' * 40;
    final report = CuratedMemoryOps.extract(CuratedMemoryOps.encode([
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.add,
          file: CuratedMemoryFile.memory,
          text: 'b' * 20),
    ]));
    store.apply(report);
    expect(report.rejected, hasLength(1));
    expect(report.rejected.first, contains('anggaran'));
    expect(store.memoryText, 'a' * 40);
  });

  test('REPLACE dengan teks tidak ditemukan ditolak', () async {
    final store = await _store(tmp);
    final report = CuratedMemoryOps.extract(CuratedMemoryOps.encode([
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.replace,
          file: CuratedMemoryFile.memory,
          find: 'tidak ada',
          text: 'x'),
    ]));
    store.apply(report);
    expect(report.applied, isEmpty);
    expect(report.rejected.first, contains('tidak ditemukan'));
  });

  test('save/load roundtrip atomik + snapshot prompt block', () async {
    var store = await _store(tmp);
    final report = CuratedMemoryOps.extract(CuratedMemoryOps.encode([
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.add,
          file: CuratedMemoryFile.memory,
          text: 'fakta satu'),
      CuratedMemoryOp(
          kind: CuratedMemoryOpKind.add,
          file: CuratedMemoryFile.user,
          text: 'preferensi dua'),
    ]));
    store.apply(report);
    await store.save();
    expect(File(store.memoryPath).existsSync(), isTrue);
    expect(File(store.userPath).existsSync(), isTrue);
    expect(
      Directory(File(store.memoryPath).parent.path)
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('.tmp')),
      isFalse,
    );

    store = CuratedMemoryStore(dataDir: tmp.path);
    await store.load();
    final block = store.snapshotPromptBlock();
    expect(block, contains('Memori kurasi (MEMORY.md):'));
    expect(block, contains('fakta satu'));
    expect(block, contains('Profil pengguna (USER.md):'));
    expect(block, contains('preferensi dua'));
  });

  test('snapshot kosong ketika belum ada memori', () async {
    final store = await _store(tmp);
    expect(store.isEmpty, isTrue);
    expect(store.snapshotPromptBlock(), isEmpty);
  });

  test('blok memory-ops tanpa operasi valid tetap dibersihkan dari balasan',
      () async {
    final store = await _store(tmp);
    final report = store.apply(
      CuratedMemoryOps.extract('jawaban\n```memory-ops\ngibberish\n```'),
    );
    expect(report.applied, isEmpty);
    expect(store.isEmpty, isTrue);
  });
}
