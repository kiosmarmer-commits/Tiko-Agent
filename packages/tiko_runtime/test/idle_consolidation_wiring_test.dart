import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

const _config = '''
profile: default
workspace: WORKSPACE
data_dir: DATA
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
memory:
  idle_consolidation:
    enabled: ENABLED
    idle_turns: 2
    min_candidates: 3
mcp:
  servers: []
''';

Future<String> _prepare(Directory temp, {required bool enabled}) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    _config
        .replaceAll('WORKSPACE', temp.path)
        .replaceAll('DATA', p.join(temp.path, 'data'))
        .replaceAll('ENABLED', enabled ? 'true' : 'false'),
  );
  return config.path;
}

void main() {
  test('E2 wiring: nonaktif (default) -> konsolidator tidak dibuat', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_ic_off_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp, enabled: false);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.idleConsolidatorForTest, isNull);
  });

  test('E2 wiring: aktif -> konsolidator terpasang, pass best-effort jalan',
      () async {
    final temp = await Directory.systemTemp.createTemp('tiko_ic_on_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp, enabled: true);
    final rt = await TikoRuntime.create(configPath: configPath);
    addTearDown(rt.close);
    expect(rt.idleConsolidatorForTest, isNotNull);

    // Tanpa kandidat memori -> pass mengembalikan null tanpa error.
    final report = await rt.runIdleConsolidationForTest('s-e2');
    expect(report, isNull);
  });
}
