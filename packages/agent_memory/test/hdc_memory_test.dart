import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  group('HdcVector', () {
    test('random deterministik terhadap seed rng yang sama', () {
      final a = HdcVector.random(10000, Random(42));
      final b = HdcVector.random(10000, Random(42));
      expect(a.hammingDistance(b), 0);
    });

    test('random vs random similarity sekitar 0.5', () {
      final a = HdcVector.random(10000, Random(1));
      final b = HdcVector.random(10000, Random(2));
      final sim = a.similarity(b);
      expect(sim, inInclusiveRange(0.4, 0.6));
    });

    test('identik → similarity 1.0', () {
      final a = HdcVector.random(1000, Random(7));
      expect(a.similarity(a), 1.0);
    });

    test('bind bersifat self-inverse (XOR): a.bind(b).bind(a) == b', () {
      final a = HdcVector.random(10000, Random(3));
      final b = HdcVector.random(10000, Random(4));
      final unbound = a.bind(b).bind(a);
      expect(unbound.similarity(b), 1.0);
    });

    test('bundle majority: vektor condong ke a → similarity tinggi', () {
      final a = HdcVector.random(10000, Random(5));
      final noise = [
        HdcVector.random(10000, Random(6)),
        HdcVector.random(10000, Random(7)),
        HdcVector.random(10000, Random(8)),
      ];
      final bundled =
          HdcVector.bundle([a, ...noise, a, a, a], 10000);
      expect(bundled.similarity(a), greaterThan(0.9));
    });

    test('bundle kosong melempar ArgumentError', () {
      expect(() => HdcVector.bundle([], 10000), throwsArgumentError);
    });

    test('permutasi: vektor terrotasi punya similarity rendah ke asal', () {
      final a = HdcVector.random(10000, Random(9));
      final rotated = a.permute(7);
      // Rotasi bit siklik memindahkan bit — similarity mendekati 0.5.
      expect(rotated.similarity(a), inInclusiveRange(0.3, 0.7));
    });

    test('permutasi mempertahankan jarak: sim(rot(a),rot(b)) == sim(a,b)', () {
      final a = HdcVector.random(10000, Random(10));
      final b = HdcVector.random(10000, Random(11));
      final k = 123;
      final before = a.similarity(b);
      final after = a.permute(k).similarity(b.permute(k));
      expect(after, closeTo(before, 1e-9));
    });

    test('permutasi shift 0 identik', () {
      final a = HdcVector.random(1000, Random(12));
      expect(a.permute(0).similarity(a), 1.0);
    });

    test('dimensi tidak cocok melempar ArgumentError', () {
      final a = HdcVector.random(1000, Random(13));
      final b = HdcVector.random(2000, Random(14));
      expect(() => a.similarity(b), throwsArgumentError);
      expect(() => a.bind(b), throwsArgumentError);
      expect(() => a.hammingDistance(b), throwsArgumentError);
    });

    test('zero vector: similarity ke vektor acak = 0.5 (semua bit 0)', () {
      final z = HdcVector.zero(10000);
      final a = HdcVector.random(10000, Random(15));
      expect(z.similarity(a), inInclusiveRange(0.4, 0.6));
    });
  });

  group('HdcEncoder', () {
    test('encode deterministik: seed sama → vektor sama', () {
      final e1 = HdcEncoder(seed: 7);
      final e2 = HdcEncoder(seed: 7);
      final v1 = e1.encode('kunci mobil di atas meja');
      final v2 = e2.encode('kunci mobil di atas meja');
      expect(v1.hammingDistance(v2), 0);
    });

    test('seed berbeda → vektor berbeda (similarity ~0.5)', () {
      final e1 = HdcEncoder(seed: 7);
      final e2 = HdcEncoder(seed: 8);
      final sim =
          e1.encode('kunci mobil').similarity(e2.encode('kunci mobil'));
      expect(sim, inInclusiveRange(0.4, 0.6));
    });

    test('teks mirip lebih dekat daripada teks tak berkaitan', () {
      final enc = HdcEncoder();
      final q = enc.encode('kunci mobil ada di atas meja kayu');
      final mirip = enc.encode('kunci mobil di atas meja kayu');
      final beda = enc.encode('resep masakan pedas ala restoran');
      expect(q.similarity(mirip), greaterThan(q.similarity(beda)));
    });

    test('teks kosong → zero vector', () {
      final enc = HdcEncoder();
      expect(enc.encode('').hammingDistance(HdcVector.zero(10000)), 0);
      expect(enc.encode('   ').hammingDistance(HdcVector.zero(10000)), 0);
    });

    test('encode case-insensitive (lowercase + trim)', () {
      final enc = HdcEncoder();
      final a = enc.encode('Kunci Mobil');
      final b = enc.encode('kunci mobil');
      expect(a.hammingDistance(b), 0);
    });

    test('teks sangat panjang dibatasi 512 trigram (tidak error)', () {
      final enc = HdcEncoder(dimensions: 1000);
      final v = enc.encode('abc ' * 1000);
      expect(v.dimensions, 1000);
    });
  });

  group('HdcMemory', () {
    HdcMemory buildMemory({int maxEntries = 1000}) =>
        HdcMemory(dimensions: 1000, maxEntries: maxEntries, seed: 99);

    test('remember + recall round-trip: teks sama → similarity 1.0', () {
      final mem = buildMemory();
      mem.remember('k1', 'kunci mobil ada di atas meja kayu');
      final hits = mem.recall('kunci mobil ada di atas meja kayu', topK: 1);
      expect(hits, isNotEmpty);
      expect(hits.first.entry.id, 'k1');
      expect(hits.first.similarity, 1.0);
    });

    test('recall mengurutkan similarity menurun', () {
      final mem = buildMemory();
      mem.remember('a', 'kunci mobil di atas meja');
      mem.remember('b', 'resep masakan pedas restoran');
      final hits = mem.recall('kunci mobil di atas meja', topK: 2);
      expect(hits.length, 2);
      expect(hits.first.entry.id, 'a');
      expect(hits.first.similarity,
          greaterThanOrEqualTo(hits.last.similarity));
    });

    test('recall minSimilarity memfilter hasil', () {
      final mem = buildMemory();
      mem.remember('a', 'kunci mobil di atas meja');
      mem.remember('b', 'resep masakan pedas restoran');
      final hits = mem.recall('kunci mobil di atas meja', minSimilarity: 0.99);
      // Hanya entri identik (atau sangat dekat) yang lolos.
      expect(hits.every((h) => h.similarity >= 0.99), isTrue);
    });

    test('recall topK dibatasi', () {
      final mem = buildMemory();
      for (var i = 0; i < 10; i++) {
        mem.remember('e$i', 'entri nomor $i tentang kunci');
      }
      expect(mem.recall('kunci', topK: 3).length, 3);
      expect(mem.recall('kunci', topK: 50).length, 10);
    });

    test('recall query kosong → konstanta kosong', () {
      final mem = buildMemory();
      mem.remember('a', 'teks');
      expect(mem.recall(''), isEmpty);
      expect(mem.recall('   '), isEmpty);
    });

    test('recall pada memori kosong → kosong', () {
      final mem = buildMemory();
      expect(mem.recall('apa saja'), isEmpty);
    });

    test('forget: true bila ada, false bila tidak', () {
      final mem = buildMemory();
      mem.remember('a', 'teks');
      expect(mem.forget('a'), isTrue);
      expect(mem.forget('a'), isFalse);
      expect(mem.length, 0);
    });

    test('clear mengosongkan semua', () {
      final mem = buildMemory();
      mem.remember('a', 'teks satu');
      mem.remember('b', 'teks dua');
      mem.clear();
      expect(mem.length, 0);
    });

    test('overwrite id sama tidak menduplikasi', () {
      final mem = buildMemory();
      mem.remember('a', 'versi satu');
      mem.remember('a', 'versi dua');
      expect(mem.length, 1);
      final hits = mem.recall('versi dua', topK: 5);
      expect(hits.first.entry.text, 'versi dua');
    });

    test('eviksi FIFO saat melebihi maxEntries', () {
      final mem = buildMemory(maxEntries: 3);
      mem.remember('e1', 'entri satu kunci');
      mem.remember('e2', 'entri dua kunci');
      mem.remember('e3', 'entri tiga kunci');
      mem.remember('e4', 'entri empat kunci');
      expect(mem.length, 3);
      expect(mem.forget('e1'), isFalse); // tertua sudah ter eviction
      expect(mem.forget('e4'), isTrue);
    });

    test('remember validasi id dan text', () {
      final mem = buildMemory();
      expect(() => mem.remember('', 'teks'), throwsArgumentError);
      expect(() => mem.remember('x' * 129, 'teks'), throwsArgumentError);
      expect(() => mem.remember('ok', ''), throwsArgumentError);
      expect(() => mem.remember('ok', 'y' * 10001), throwsArgumentError);
    });

    test('clock dapat diinjeksi untuk createdAt', () {
      final fixed = DateTime.utc(2026, 11, 17);
      final mem = HdcMemory(
        dimensions: 1000,
        clock: () => fixed,
      );
      mem.remember('a', 'teks');
      final hits = mem.recall('teks', topK: 1);
      expect(hits.first.entry.createdAt, fixed);
    });
  });

  group('HdcMemoryTool', () {
    Future<(ToolResult, HdcMemory)> runTool(
      Map<String, dynamic> args, {
      HdcMemory? memory,
    }) async {
      final mem = memory ??
          HdcMemory(dimensions: 1000, seed: 5);
      final tool = HdcMemoryTool(mem);
      final ctx = ToolContext(
        session: Session(id: 's1', channel: 'test', userKey: 'u1'),
        workspacePath: '/tmp',
      );
      return (await tool.run(args, ctx), mem);
    }

    test('metadata tool', () {
      final tool = HdcMemoryTool(HdcMemory(dimensions: 1000));
      expect(tool.spec.name, 'hdc_memory');
      expect(tool.spec.risk, 'low');
    });

    test('aksi remember lalu recall menghasilkan format similarity=', () async {
      final (r1, mem) = await runTool(
        {'action': 'remember', 'id': 'kunci', 'text': 'kunci mobil di meja'},
      );
      expect(r1.isError, isFalse);
      expect(r1.content, contains('id=kunci'));

      final (r2, _) = await runTool(
        {'action': 'recall', 'query': 'kunci mobil di meja'},
        memory: mem,
      );
      expect(r2.isError, isFalse);
      expect(r2.content, contains('similarity='));
      expect(r2.content, contains('kunci'));
    });

    test('recall tanpa hasil → pesan kosong, bukan error', () async {
      final (r, _) = await runTool({'action': 'recall', 'query': 'zzz'});
      expect(r.isError, isFalse);
      expect(r.content, contains('Tidak ada hasil'));
    });

    test('remember tanpa id/text → error', () async {
      final (r1, _) = await runTool({'action': 'remember', 'id': 'x'});
      expect(r1.isError, isTrue);
      final (r2, _) = await runTool({'action': 'remember', 'text': 'y'});
      expect(r2.isError, isTrue);
    });

    test('recall tanpa query → error', () async {
      final (r, _) = await runTool({'action': 'recall'});
      expect(r.isError, isTrue);
    });

    test('forget ada → OK; forget tidak ada → error', () async {
      final (r1, mem) = await runTool(
        {'action': 'remember', 'id': 'a', 'text': 'teks'},
      );
      expect(r1.isError, isFalse);

      final (r2, _) = await runTool({'action': 'forget', 'id': 'a'},
          memory: mem);
      expect(r2.isError, isFalse);
      expect(r2.content, contains('OK dihapus'));

      final (r3, _) = await runTool({'action': 'forget', 'id': 'a'},
          memory: mem);
      expect(r3.isError, isTrue);
    });

    test('stats menampilkan entries/maxEntries/dimensions', () async {
      final (r, _) = await runTool({'action': 'stats'});
      expect(r.isError, isFalse);
      expect(r.content, contains('entries='));
      expect(r.content, contains('maxEntries='));
      expect(r.content, contains('dimensions='));
    });

    test('aksi tidak dikenal jatuh ke stats (fail-closed aman)', () async {
      final (r, _) = await runTool({'action': 'hocus'});
      expect(r.isError, isFalse);
      expect(r.content, contains('entries='));
    });
  });
}
