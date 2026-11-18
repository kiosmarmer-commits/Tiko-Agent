import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

/// GUI-P2-04: Run-inspector — registri turn live/riwayat di
/// [TikoRuntime.turnInspector] (in-memory bounded; tidak memengaruhi turn).
void main() {
  test('TurnInspector unit: begin/finish/fail + langkah tool + snapshot', () {
    final inspector = TurnInspector();

    final run = inspector.begin(session: 's-1', channel: 'web', input: 'halo');
    inspector.recordTool(
      run.id,
      tool: 'datetime',
      verdict: 'allowed',
      isError: false,
      durationMs: 12,
    );
    final activity = inspector.snapshot();
    expect(activity['active'], hasLength(1));
    expect(((activity['active'] as List).first as Map)['state'], 'running');
    expect(
        ((activity['active'] as List).first as Map)['steps'], hasLength(1));

    inspector.finish(run.id,
        success: true, tokensUsed: 30, toolCalls: 1, answer: 'selesai');
    final snap = inspector.snapshot();
    final recent = (snap['recent'] as List).first as Map;
    expect(recent['state'], 'done');
    expect(recent['success'], isTrue);
    expect(recent['tokens_used'], 30);
    expect(recent['steps'], hasLength(1));
    expect((recent['steps'] as List).first,
        containsPair('tool', 'datetime'));

    final failed = inspector.begin(
        session: 's-2/sub/1/1', channel: 'cli', input: 'sub');
    final active = (inspector.snapshot()['active'] as List).first as Map;
    expect(active['subagent'], isTrue);
    expect(active['parent'], 's-2');
    inspector.fail(failed.id, error: 'boom');
    final afterFail = inspector.snapshot();
    final failedEntry = (afterFail['recent'] as List).first as Map;
    expect(failedEntry['state'], 'error');
    expect(failedEntry['error'], 'boom');
    expect(failedEntry['success'], isFalse);
  });

  test('TurnInspector: ring terbatas + langkah dibatasi 100', () {
    final inspector = TurnInspector();
    for (var i = 0; i < 60; i++) {
      final r =
          inspector.begin(session: 's-$i', channel: 'web', input: 'msg-$i');
      for (var s = 0; s < 130; s++) {
        inspector.recordTool(r.id,
            tool: 'datetime',
            verdict: 'allowed',
            isError: false,
            durationMs: 1);
      }
      inspector.finish(r.id, success: true, tokensUsed: 1, toolCalls: 130);
    }
    final snap = inspector.snapshot();
    expect(snap['truncated'], isTrue);
    final recent = snap['recent'] as List;
    expect(recent.length, 40);
    final anyRun = recent.first as Map;
    expect((anyRun['steps'] as List).length, 100);
  });

  test(
      'chatWithStatus meminstrumentasi run: mock single_tool merekam step datetime',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_runs_');
    addTearDown(() => temp.delete(recursive: true));
    final config = File(p.join(temp.path, 'agent.yaml'));
    await config.writeAsString('''
profile: default
workspace: ${p.join(temp.path, 'workspace')}
data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
      scenario: single_tool
mcp:
  servers: []
''');
    final rt = await TikoRuntime.create(configPath: config.path, safe: false);
    addTearDown(rt.close);

    final result = await rt.chatWithStatus(
      'jam berapa sekarang?',
      sessionId: 'inspect-1',
      channel: 'test',
    );
    expect(result.success, isTrue);

    final snap = rt.turnInspectorSnapshot();
    final recent = snap['recent'] as List;
    expect(recent, isNotEmpty);
    final entry = recent.first as Map;
    expect(entry['session'], 'inspect-1');
    expect(entry['state'], 'done');
    expect(entry['success'], isTrue);
    expect(entry['subagent'], isFalse);
    expect(entry['duration_ms'], isNotNull);
    final steps = entry['steps'] as List;
    expect(steps, isNotEmpty);
    expect((steps.first as Map)['tool'], 'datetime');
    expect((steps.first as Map)['is_error'], isFalse);
  });
}
