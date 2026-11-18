import 'dart:convert';
import 'dart:io';

import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

/// GUI-P1-11: audit query browser — filter tool/session/risk/verdict/taint,
/// rentang waktu since/until, cakupan file JSONL harian (lintas restart),
/// dedupe, dan pagination.
void main() {
  late Directory temp;
  late TikoRuntime rt;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audit-query-test');
    final configPath = File('${temp.path}/config.yaml');
    await configPath.writeAsString('''
providers:
  mock:
    type: openai_compat
    base_url: http://127.0.0.1:1/v1
    api_key: sk-test
default_provider: mock
data_dir: ${temp.path}/data
memory:
  backend: json
logs_dir: ${temp.path}/logs
security:
  mode: ask
mcp:
  servers: []
''');
    rt = await TikoRuntime.create(configPath: configPath.path);
    addTearDown(rt.close);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<void> write({required String tool, String session = 's-1',
      String risk = 'low', String verdict = 'allow', bool taint = false,
      String? result}) async {
    await rt.audit.log(
      sessionId: session,
      tool: tool,
      args: {'x': 'y'},
      risk: risk,
      verdict: verdict,
      resultSummary: result,
      taint: taint,
    );
  }

  test('tanpa filter: semua entri urut terbaru dulu + total', () async {
    await write(tool: 'datetime');
    await write(tool: 'shell.exec', risk: 'high', verdict: 'approve');
    final r = await rt.auditQuery();
    expect(r['total'], 2);
    final entries = r['entries'] as List;
    expect((entries.first as Map)['tool'], 'shell.exec');
    expect((entries.last as Map)['tool'], 'datetime');
  });

  test('filter tool case-insensitive substring + risk/verdict', () async {
    await write(tool: 'datetime');
    await write(tool: 'shell.exec', risk: 'high', verdict: 'approve');
    await write(tool: 'web.fetch');
    final r = await rt.auditQuery(tool: 'SHELL', risk: 'high');
    expect(r['total'], 1);
    expect((r['entries'].first as Map)['verdict'], 'approve');
    final r2 = await rt.auditQuery(verdict: 'ALLOW');
    expect(r2['total'], 2);
  });

  test('filter session + taint', () async {
    await write(tool: 'datetime');
    await write(tool: 'shell.exec', session: 's-evil', taint: true);
    expect((await rt.auditQuery(session: 's-evil'))['total'], 1);
    expect((await rt.auditQuery(taint: true))['total'], 1);
    expect((await rt.auditQuery(taint: false))['total'], 1);
    expect((await rt.auditQuery(session: 's-ada'))['total'], 0);
  });

  test('rentang since/until membatasi hasil', () async {
    await write(tool: 'a');
    await Future.delayed(const Duration(milliseconds: 10));
    final middle = DateTime.now().toUtc();
    await Future.delayed(const Duration(milliseconds: 10));
    await write(tool: 'b');
    expect((await rt.auditQuery(since: middle))['total'], 1);
    expect((await rt.auditQuery(until: middle))['total'], 1);
    expect((await rt.auditQuery())['total'], 2);
  });

  test('limit + offset paginate', () async {
    for (var i = 0; i < 5; i++) {
      await write(tool: 't$i');
    }
    final page = await rt.auditQuery(limit: 2, offset: 1);
    expect(page['total'], 5);
    expect((page['entries'] as List).length, 2);
    final page2 = await rt.auditQuery(limit: 2, offset: 4);
    expect((page2['entries'] as List).length, 1);
  });

  test('entri prah restart dibaca dari file JSONL (dedupe dgn in-memory)',
      () async {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final file = File('${temp.path}/logs/audit-${day.replaceAll('-', '')}.jsonl');
    await file.parent.create(recursive: true);
    final old = {
      'ts': '2026-11-01T00:00:00.000Z',
      'session': 's-old',
      'tool': 'legacy.tool',
      'args': <String, dynamic>{},
      'risk': 'medium',
      'verdict': 'allow',
      'result': null,
      'duration_ms': null,
      'error': null,
      'taint': false,
    };
    await file.writeAsString('${jsonEncode(old)}\n');
    await write(tool: 'datetime');
    final r = await rt.auditQuery(daysBack: 30);
    expect(r['total'], 2);

    await rt.audit.log(
      sessionId: 's-old',
      tool: 'legacy.tool',
      args: {},
      risk: 'medium',
      verdict: 'allow',
    );
    final r2 = await rt.auditQuery(daysBack: 30);
    expect(r2['total'], 3); // tidak ada duplikat lintas sumber
  });
}
