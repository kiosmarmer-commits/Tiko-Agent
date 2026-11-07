import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:tiko_runtime/tiko_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('runtime admin lists and deletes facts through SafeMemoryStore', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_memory_admin_');
    final config = File('${temp.path}/agent.yaml');
    await config.writeAsString(TikoConfig.setupYaml(
      provider: 'mock',
      workspace: 'workspace',
    ));
    final runtime = await TikoRuntime.create(configPath: config.path);
    try {
      await runtime.memory.upsertFact(const Fact(
        id: 'admin-fact',
        text: 'Prefer Indonesian language in responses',
        provenance: Provenance.user,
        confidence: 0.95,
        state: 'active',
      ));
      final rows = await runtime.listMemories();
      expect(rows.map((row) => row['id']), contains('admin-fact'));
      expect(await runtime.deleteMemory('admin-fact'), isTrue);
      expect(await runtime.deleteMemory('missing-fact'), isFalse);
      expect(
        (await runtime.listMemories()).map((row) => row['id']),
        isNot(contains('admin-fact')),
      );
    } finally {
      await runtime.close();
      await temp.delete(recursive: true);
    }
  });
}
