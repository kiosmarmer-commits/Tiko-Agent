import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late FtsIndex fts;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fts_bm25_');
    fts = FtsIndex('${tmp.path}/fts.json');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('dokumen dengan dua term query di atas dokumen satu term', () {
    fts.upsert('a', 'kopi susu gula aren enak');
    fts.upsert('b', 'kopi hitam pekat');
    fts.upsert('c', 'teh tawar dingin');
    final hits = fts.search('kopi susu');
    expect(hits, hasLength(2));
    expect(hits[0].id, 'a');
    expect(hits[1].id, 'b');
  });

  test('skor ternormalisasi, maksimal 1', () {
    fts.upsert('a', 'kopi susu gula aren');
    fts.upsert('b', 'kopi hitam');
    final hits = fts.search('kopi susu');
    expect(hits.first.score, greaterThan(0));
    expect(hits.first.score, lessThanOrEqualTo(1));
  });

  test('IDF: term langka mengalahkan pengulangan term umum', () {
    fts.upsert('a', 'kopi kopi kopi');
    fts.upsert('b', 'susu');
    fts.upsert('c', 'kopi');
    final hits = fts.search('kopi susu');
    expect(hits.first.id, 'b');
  });

  test('saturasi TF: pengulangan 6x hanya sekitar 19 persen lebih tinggi', () {
    fts.upsert('x', 'susu susu susu susu susu susu');
    fts.upsert('y', 'susu');
    final hits = fts.search('susu');
    expect(hits.first.id, 'x');
    final ratio = hits[0].score / hits[1].score;
    expect(ratio, lessThan(1.5));
  });

  test('remove menghapus posting dan panjang dokumen', () {
    fts.upsert('a', 'kopi susu');
    fts.remove('a');
    expect(fts.search('kopi'), isEmpty);
  });
}
