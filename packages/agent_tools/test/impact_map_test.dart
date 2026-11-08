import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko_impact');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: tmp.path,
      );

  test('status: file ada, baru, dan di luar workspace', () async {
    File('${tmp.path}/ada.txt').writeAsStringSync('isi');
    final res = await const ImpactMapTool().run({
      'steps': [
        {'action': 'edit', 'target': 'ada.txt'},
        {'action': 'buat', 'target': 'baru.txt'},
        {'action': 'hapus', 'target': '../luar'},
      ],
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('file ada (3 byte)'));
    expect(res.content, contains('baru (belum ada)'));
    expect(res.content, contains('DI LUAR WORKSPACE'));
    expect(
      res.content,
      contains('Ringkasan: 1 sudah ada, 1 baru, 1 di luar'),
    );
  });

  test('target duplikat memunculkan peringatan', () async {
    final res = await const ImpactMapTool().run({
      'steps': [
        {'action': 'edit', 'target': 'a.txt'},
        {'action': 'hapus', 'target': 'a.txt'},
      ],
    }, ctx());
    expect(res.isError, isFalse);
    expect(res.content, contains('PERINGATAN: a.txt disentuh 2 kali'));
  });

  test('steps tidak valid ditolak', () async {
    final res = await const ImpactMapTool().run({'steps': 'x'}, ctx());
    expect(res.isError, isTrue);
    final resEmpty = await const ImpactMapTool().run(
      {'steps': []},
      ctx(),
    );
    expect(resEmpty.isError, isTrue);
    final resBad = await const ImpactMapTool().run({
      'steps': [
        {'action': ''},
      ],
    }, ctx());
    expect(resBad.isError, isTrue);
  });
}
