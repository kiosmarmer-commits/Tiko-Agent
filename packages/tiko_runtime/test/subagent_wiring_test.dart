import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('runtime memasang runner subagent pada spawn_subagent', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_subagent_');
    addTearDown(() => temp.delete(recursive: true));

    final runtime = await TikoRuntime.create(
      configPath: '${temp.path}/missing.yaml',
    );
    addTearDown(runtime.approvals.close);
    addTearDown(runtime.events.close);

    final tool = runtime.registry.get('spawn_subagent');
    expect(tool, isNotNull);
    final spawn = tool!;
    final session = Session(
      id: 'subagent-wiring-test',
      channel: 'cli',
      userKey: 'tester',
    );
    final result = await spawn.run(
      {
        'goal': 'ringkas tujuan proyek ini',
        'context': 'proyek: Tiko-Agent',
      },
      ToolContext(session: session, workspacePath: runtime.workspace),
    );

    expect(result.isError, isFalse);
    expect(result.content, isNot(contains('Host belum memasang')));
    expect(result.content, isNot(contains('SUBAGENT_REQUEST')));
  });
}
