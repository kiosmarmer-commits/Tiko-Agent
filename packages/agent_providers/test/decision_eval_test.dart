import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  final decision = HeuristicDecisionProvider();
  final router = Router(
    providers: {'mock': MockLlmProvider()},
    defaultProviderId: 'mock',
    decision: decision,
  );

  test('heuristic flags dangerous rm -rf', () async {
    final r = await router.route(
      'Jalankan rm -rf / di server',
      Session(id: 's', channel: 'cli', userKey: 'u'),
    );
    expect(r.risk, anyOf('high', 'critical'));
    expect(r.needTools, isTrue);
  });

  test('heuristic plain chat no tools', () async {
    final r = await router.route(
      'Halo, apa kabar?',
      Session(id: 's', channel: 'cli', userKey: 'u'),
    );
    expect(r.needTools, isFalse);
    expect(r.risk, 'low');
  });

  test('heuristic calc needs tools', () async {
    final r = await router.route(
      'Hitung (12+8)*3',
      Session(id: 's', channel: 'cli', userKey: 'u'),
    );
    expect(r.needTools, isTrue);
  });

  test('eval set accuracy report (heuristic baseline)', () async {
    final paths = [
      'test/eval/router_id_50.yaml',
      '../../test/eval/router_id_50.yaml',
      '../../../test/eval/router_id_50.yaml',
    ];
    File? file;
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) {
        file = f;
        break;
      }
    }
    if (file == null) {
      // soft skip
      return;
    }
    final lines = file.readAsLinesSync();
    // minimal yaml-ish parse for our simple format
    final items = <Map<String, String>>[];
    Map<String, String>? cur;
    for (final line in lines) {
      final t = line.trimRight();
      if (t.trim().startsWith('- input:')) {
        if (cur != null) items.add(cur);
        cur = {
          'input': t
              .split('input:')
              .sublist(1)
              .join('input:')
              .trim()
              .replaceAll('"', ''),
        };
      } else if (cur != null && t.trim().startsWith('expect_need_tool:')) {
        cur['expect_need_tool'] = t.split(':').last.trim();
      } else if (cur != null && t.trim().startsWith('expect_danger:')) {
        cur['expect_danger'] = t.split(':').last.trim();
      }
    }
    if (cur != null) items.add(cur);

    var toolOk = 0;
    var dangerOk = 0;
    final session = Session(id: 'eval', channel: 'cli', userKey: 'eval');
    for (final it in items) {
      final input = it['input'] ?? '';
      final expTool = it['expect_need_tool'] == 'true';
      final expDanger = it['expect_danger'] ?? 'low';
      final r = await router.route(input, session);
      if (r.needTools == expTool) toolOk++;
      final dangerMatch = switch (expDanger) {
        'low' => r.risk == 'low',
        'high' => r.risk == 'high' || r.risk == 'critical',
        'critical' => r.risk == 'critical' || r.risk == 'high',
        _ => true,
      };
      if (dangerMatch) dangerOk++;
    }
    final n = items.length;
    expect(n, greaterThanOrEqualTo(40));
    final toolAcc = toolOk / n;
    final dangerAcc = dangerOk / n;
    // Heuristic baseline should be reasonably good on this handcrafted set
    expect(toolAcc, greaterThan(0.7));
    expect(dangerAcc, greaterThan(0.7));
    // ignore: avoid_print
    print(
      'EVAL n=$n tool_acc=${toolAcc.toStringAsFixed(3)} danger_acc=${dangerAcc.toStringAsFixed(3)}',
    );
  });
}
