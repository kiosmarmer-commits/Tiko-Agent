import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Session session;
  late ErrorMemoryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('errmem_');
    session = Session(id: 's', channel: 'cli', userKey: 'u');
    store = ErrorMemoryStore();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ToolContext ctx() =>
      ToolContext(session: session, workspacePath: tmp.path);

  test('normalisasi signature deterministik', () {
    final a = ErrorMemoryStore.normalize(
        'ECONNREFUSED 127.0.0.1:5432 code 0xdead at /app/main.dart:42');
    final b = ErrorMemoryStore.normalize(
        'ECONNREFUSED 10.0.0.9:9999 code 0xbeef at /app/main.dart:7');
    expect(a, b);
    expect(a, contains('<hex>'));
    expect(a, contains('<n>'));
  });

  test('record lalu lookup identik', () async {
    final r1 = await ErrorRecordTool(store: store).run({
      'output': 'Exception: connection refused port 5432',
      'cause': 'Postgres tidak jalan',
      'fix': 'Start the database',
    }, ctx());
    expect(r1.isError, isFalse);
    final r2 = await ErrorLookupTool(store: store).run({
      'output': 'Exception: connection refused port 5432',
    }, ctx());
    expect(r2.isError, isFalse);
    expect(r2.content, contains('Postgres tidak jalan'));
    expect(r2.content, contains('connection refused'));
  });

  test('error mirip dengan path/angka beda tetap cocok', () async {
    await ErrorRecordTool(store: store).run({
      'output': 'Error: cannot open file /tmp/a.log line 12',
      'cause': 'File belum dibuat',
      'fix': 'Buat file dulu',
    }, ctx());
    final r = await ErrorLookupTool(store: store).run({
      'output': 'Error: cannot open file /var/b.log line 99',
    }, ctx());
    expect(r.isError, isFalse);
    expect(r.content, contains('File belum dibuat'));
  });

  test('error tak relevan tidak dikembalikan', () async {
    await ErrorRecordTool(store: store).run({
      'output': 'Exception: connection refused port 5432',
      'cause': 'DB down',
      'fix': 'start db',
    }, ctx());
    final r = await ErrorLookupTool(store: store).run({
      'output': 'SyntaxError: unexpected token in parser',
    }, ctx());
    expect(r.content, contains('Tidak ada error serupa'));
  });

  test('record ulang menambah hits tanpa duplikat', () async {
    final rec = ErrorRecordTool(store: store);
    await rec.run({
      'output': 'oops failed',
      'cause': 'c1',
      'fix': 'f1',
    }, ctx());
    await rec.run({
      'output': 'oops failed',
      'cause': 'c2',
      'fix': 'f2',
    }, ctx());
    final r = await ErrorLookupTool(store: store).run({
      'output': 'oops failed',
    }, ctx());
    expect(r.content, contains('hits: 2'));
    expect(r.content, contains('c2'));
  });

  test('persist roundtrip antar instance', () async {
    final path = '${tmp.path}/errors.json';
    final store1 = ErrorMemoryStore(persistPath: path);
    await ErrorRecordTool(store: store1).run({
      'output': 'panic: runtime error index out of range',
      'cause': 'Slice kosong',
      'fix': 'Cek panjang slice',
    }, ctx());
    expect(File(path).existsSync(), isTrue);
    final store2 = ErrorMemoryStore(persistPath: path);
    final r = await ErrorLookupTool(store: store2).run({
      'output': 'panic: runtime error index out of range',
    }, ctx());
    expect(r.content, contains('Slice kosong'));
  });
}
