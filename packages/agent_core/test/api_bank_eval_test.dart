import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// CI menjalankan `dart test packages/agent_core/test` dari root repo;
/// cari fixture dengan walk-up agar tidak tergantung working directory.
String _fixtureContent() {
  var dir = Directory.current.absolute.path;
  for (var i = 0; i < 8; i++) {
    for (final candidate in [
      p.join(dir, 'test', 'fixtures', 'api_bank_mini.jsonl'),
      p.join(dir, 'packages', 'agent_core', 'test', 'fixtures',
          'api_bank_mini.jsonl'),
    ]) {
      final f = File(candidate);
      if (f.existsSync()) return f.readAsStringSync();
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  throw StateError('fixture api_bank_mini.jsonl tidak ditemukan');
}

void main() {
  const adapter = ApiBankAdapter();

  test('APIBANK-1: parse JSONL — baris invalid dilewati tanpa raise', () {
    final cases = adapter.parseJsonl('''
{"id":"a1","query":"cek cuaca","api_docs":[{"name":"get_weather","description":"cuaca"}],"expected_calls":[{"name":"get_weather"}]}

bukan json
{"query":"tanpa id"}
''');
    expect(cases, hasLength(2));
    expect(cases.first.id, 'a1');
    expect(cases.first.expectedCalls.single.name, 'get_weather');
    expect(cases.last.id, isNotEmpty, reason: 'id kosong diberi fallback');
    expect(cases.last.requiresRefresh, isFalse);
  });

  test('APIBANK-2: toEvalCases → EvalCase tool_precision', () {
    final cases = adapter.parseJsonl(
      '{"id":"a2","query":"kirim email","api_docs":[{"name":"send_email","description":"x"}],"expected_calls":[{"name":"send_email","arguments":{"to":"a@b.c"}}],"requires_refresh":false}',
    );
    final evals = adapter.toEvalCases(cases);
    expect(evals, hasLength(1));
    final e = evals.single;
    expect(e.kind, EvalKind.toolPrecision);
    expect(e.expectedTools, {'send_email'});
    expect(e.meta['api_bank'], isTrue);
    expect(e.prompt, contains('send_email'));
  });

  test('APIBANK-3: harness end-to-end — pass dan fail', () async {
    final content = _fixtureContent();
    final evals = adapter.fromJsonl(content);
    expect(evals, hasLength(3));
    final refresh = evals.firstWhere((e) => e.id == 'apibank-003');
    expect(refresh.prompt, contains('refresh'));

    Future<EvalTurnResult> goodRunner(EvalCase c) async => EvalTurnResult(
          text: 'selesai',
          success: true,
          tokensUsed: 10,
          latencyMs: 5,
          toolCalls: [
            for (final name in c.expectedTools)
              ToolCallTrace(name: name, args: const {}, isError: false, durationMs: 1),
          ],
        );

    Future<EvalTurnResult> badRunner(EvalCase c) async => const EvalTurnResult(
          text: 'selesai',
          success: true,
        );

    final good = await EvalHarness(runner: goodRunner)
        .run(evals, label: 'api-bank-good');
    expect(good.toolPrecisionRate, 1.0);

    final bad = await EvalHarness(runner: badRunner)
        .run(evals, label: 'api-bank-bad');
    expect(bad.toolPrecisionRate, 0.0);
    expect(bad.regressionsVs(good), containsAll(['apibank-001']));
  });

  test('APIBANK-4: round-trip toJson/fromJson', () {
    const c = ApiBankCase(
      id: 'rt',
      query: 'q',
      apiDocs: [ApiDoc(name: 'n', description: 'd')],
      expectedCalls: [ExpectedApiCall(name: 'n', arguments: {'x': 1})],
      requiresRefresh: true,
    );
    final back = ApiBankCase.fromJson(c.toJson());
    expect(back.id, 'rt');
    expect(back.apiDocs.single.name, 'n');
    expect(back.expectedCalls.single.arguments, {'x': 1});
    expect(back.requiresRefresh, isTrue);
  });
}
