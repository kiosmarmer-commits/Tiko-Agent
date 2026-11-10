import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:test/test.dart';

void main() {
  test('fts index search', () async {
    final tmp = Directory.systemTemp.createTempSync('fts_');
    final fts = FtsIndex('${tmp.path}/fts.json');
    fts.upsert('1', 'Pengguna tinggal di Jakarta');
    fts.upsert('2', 'Preferensi bahasa Indonesia');
    await fts.save();
    final hits = fts.search('Jakarta');
    expect(hits, isNotEmpty);
    expect(hits.first.text, contains('Jakarta'));

    final fts2 = FtsIndex('${tmp.path}/fts.json');
    await fts2.load();
    expect(fts2.search('Indonesia'), isNotEmpty);
    tmp.deleteSync(recursive: true);
  });
}
