import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CodeSearchTool tool;
  late ToolContext ctx;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tiko_codesearch_');
    Directory('${root.path}/lib/src').createSync(recursive: true);

    File('${root.path}/lib/src/payment_gateway.dart').writeAsStringSync('''
class PaymentGateway {
  int retry(String id) {
    return 1;
  }
}
''');
    tool = CodeSearchTool(workspaceRoot: root.path);
    ctx = ToolContext(
      session: Session(id: 's-s19', channel: 'cli', userKey: 'u1'),
      workspacePath: root.path,
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('ranking: file definisi ditemukan dan tampil pertama', () async {
    final res = await tool.run({'query': 'payment gateway', 'limit': 5}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, startsWith('code_search:'));
    expect(res.content, contains('payment_gateway.dart'));
  });

  test('query camelCase cocok dengan snake_case di kode', () async {
    final res = await tool.run({'query': 'PaymentGateway'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, contains('payment_gateway.dart'));
  });

  test('query tanpa kecocokan: jawaban jujur tanpa error', () async {
    final res = await tool.run({'query': 'zzzqqq'}, ctx);
    expect(res.isError, isFalse);
    expect(res.content, startsWith('tidak ada'));
  });

  test('limit membatasi jumlah baris hasil', () async {
    final res = await tool.run({'query': 'payment scala', 'limit': 1}, ctx);
    expect(res.isError, isFalse);
  });

  test('query kosong ditolak', () async {
    final res = await tool.run({'query': '  '}, ctx);
    expect(res.isError, isTrue);
  });

  test('path jail: di luar workspace ditolak', () async {
    final res = await tool.run({'query': 'class', 'path': '../'}, ctx);
    expect(res.isError, isTrue);
    expect(res.content, contains('di luar workspace'));
  });

  test('subdirektori dibatasi via path', () async {
    Directory('${root.path}/docs').createSync(recursive: true);
    File('${root.path}/docs/notes.dart')
        .writeAsStringSync('class PaymentGatewayNotes {}\n');
    final res = await tool.run(
        {'query': 'PaymentGatewayNotes', 'path': 'lib', 'limit': 30}, ctx);
    expect(res.content, isNot(contains('docs/notes.dart')));
  });
}
