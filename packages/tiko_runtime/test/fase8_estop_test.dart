import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString('''
profile: default
workspace: ${temp.path}
storage:
  data_dir: ${p.join(temp.path, 'data')}
providers:
  default_chat: mock
  chat:
    mock:
      type: mock
agent:
  max_iterations: 4
''');
  return config.path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tiko_fase8_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('Estop unit', () {
    test('engage → isEngaged → payload → release', () {
      final dir = p.join(temp.path, 'd1');
      final estop = Estop(dir);
      expect(estop.isEngaged(), isFalse);
      estop.engage('maintenance');
      expect(estop.isEngaged(), isTrue);
      expect(File(estop.path).existsSync(), isTrue);
      final payload = estop.readPayload();
      expect(payload?['reason'], 'maintenance');
      expect(payload?['engaged_at'], isNotNull);
      estop.release();
      expect(estop.isEngaged(), isFalse);
    });

    test('engage tanpa alasan; release idempotent; engage ulang update', () {
      final estop = Estop(p.join(temp.path, 'd2'));
      estop.engage();
      expect(estop.isEngaged(), isTrue);
      expect(estop.readPayload()?['reason'], isNull);
      estop.release();
      estop.release();
      expect(estop.isEngaged(), isFalse);
      estop.engage('kedua');
      expect(estop.readPayload()?['reason'], 'kedua');
    });
  });

  group('ESTOP runtime wiring', () {
    test('/pause menolak pesan baru; /resume membuka kembali', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);

      final paused = await rt.chat('/pause demo');
      expect(paused, contains('ESTOP'));

      final blocked = await rt.chat('halo dunia');
      expect(blocked, contains('dijeda'));

      final blockedEvents = rt.events
          .recent(limit: 50)
          .where((e) => e['type'] == 'estop.blocked')
          .toList();
      expect(blockedEvents, isNotEmpty);
      expect(rt.estop.isEngaged(), isTrue);

      final resumed = await rt.chat('/resume');
      expect(resumed, contains('dilepas'));
      expect(rt.estop.isEngaged(), isFalse);

      final after = await rt.chat('halo lagi');
      expect(after, isNot(contains('dijeda')));
    });

    test('resume saat tidak engaged tetap graceful', () async {
      final configPath = await _prepare(temp);
      final rt = await TikoRuntime.create(configPath: configPath);
      addTearDown(rt.close);
      final out = await rt.chat('/resume');
      expect(out, contains('tidak sedang engaged'));
      expect(
        rt.events
            .recent(limit: 50)
            .where((e) => e['type'] == 'estop.released'),
        isEmpty,
      );
    });
  });
}
