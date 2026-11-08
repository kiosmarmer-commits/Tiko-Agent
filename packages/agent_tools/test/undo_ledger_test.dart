import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tiko_undo');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(
        session: Session(id: 's1', channel: 'cli', userKey: 'local'),
        workspacePath: tmp.path,
      );

  test('snapshot → overwrite → undo memulihkan isi', () async {
    final ledger = UndoLedger();
    final file = File('${tmp.path}/a.txt')..writeAsStringSync('lama');
    await RecordUndoableTool(ledger: ledger).run({
      'description': 'timpa a.txt',
      'path': 'a.txt',
    }, ctx());
    file.writeAsStringSync('baru');
    expect(file.readAsStringSync(), 'baru');
    final res = await UndoTool(ledger: ledger).run({}, ctx());
    expect(res.isError, isFalse);
    expect(file.readAsStringSync(), 'lama');
  });

  test('file baru → undo menghapus', () async {
    final ledger = UndoLedger();
    await RecordUndoableTool(ledger: ledger).run({
      'description': 'buat b.txt',
      'path': 'b.txt',
    }, ctx());
    final file = File('${tmp.path}/b.txt')..writeAsStringSync('isi');
    expect(file.existsSync(), isTrue);
    final res = await UndoTool(ledger: ledger).run({}, ctx());
    expect(res.isError, isFalse);
    expect(file.existsSync(), isFalse);
  });

  test('tanpa path, ledger kosong, dan path luar workspace', () async {
    final ledger = UndoLedger();
    final res = await RecordUndoableTool(ledger: ledger).run({
      'description': 'mulai refactor',
    }, ctx());
    expect(res.isError, isFalse);
    final undo = await UndoTool(ledger: ledger).run({}, ctx());
    expect(undo.isError, isFalse);
    final empty = await UndoTool(ledger: ledger).run({}, ctx());
    expect(empty.isError, isTrue);
    final list = await ListUndoTool(ledger: ledger).run({}, ctx());
    expect(list.isError, isTrue);

    final out = await RecordUndoableTool(ledger: ledger).run({
      'description': 'x',
      'path': '../luar.txt',
    }, ctx());
    expect(out.isError, isTrue);
  });
}
