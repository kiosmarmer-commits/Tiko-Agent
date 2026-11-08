import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LeaseManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lease_');
    manager = LeaseManager();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ToolContext ctx(String sessionId) => ToolContext(
        session: Session(id: sessionId, channel: 'cli', userKey: 'u'),
        workspacePath: tmp.path,
      );

  test('acquire, konflik antar sesi, release', () async {
    final tool = LeaseTool(manager: manager);
    final r1 = await tool.run({
      'action': 'acquire',
      'resource': 'file:src/a.go',
    }, ctx('sess-a'));
    expect(r1.isError, isFalse);
    final r2 = await tool.run({
      'action': 'acquire',
      'resource': 'file:src/a.go',
    }, ctx('sess-b'));
    expect(r2.isError, isTrue);
    expect(r2.content, contains('owner lain'));
    final r3 = await tool.run({
      'action': 'release',
      'resource': 'file:src/a.go',
    }, ctx('sess-a'));
    expect(r3.isError, isFalse);
    final r4 = await tool.run({
      'action': 'acquire',
      'resource': 'file:src/a.go',
    }, ctx('sess-b'));
    expect(r4.isError, isFalse);
  });

  test('resource tanpa prefiks jenis ditolak', () async {
    final tool = LeaseTool(manager: manager);
    final r = await tool.run({
      'action': 'acquire',
      'resource': 'src/a.go',
    }, ctx('sess-a'));
    expect(r.isError, isTrue);
    expect(r.content, contains('tidak valid'));
  });

  test('list kosong lalu terisi', () async {
    final tool = LeaseTool(manager: manager);
    final r0 = await tool.run({'action': 'list'}, ctx('sess-a'));
    expect(r0.content, contains('tidak ada lease'));
    await tool.run({
      'action': 'acquire',
      'resource': 'port:8080',
    }, ctx('sess-a'));
    final r1 = await tool.run({'action': 'list'}, ctx('sess-a'));
    expect(r1.content, contains('port:8080'));
    expect(r1.content, contains('sess-a'));
  });

  test('action tidak dikenal', () async {
    final tool = LeaseTool(manager: manager);
    final r = await tool.run({'action': 'steal'}, ctx('sess-a'));
    expect(r.isError, isTrue);
  });
}
