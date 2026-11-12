import 'dart:io';

import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('runtime refuses to execute with a fatal configuration by default', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_config_guard_');
    addTearDown(() => temp.delete(recursive: true));
    final config = File('${temp.path}/broken.yaml');
    await config.writeAsString('providers: [not-a-map]');

    await expectLater(
      TikoRuntime.create(configPath: config.path),
      throwsA(isA<ConfigValidationException>()),
    );
  });

  test('doctor checks host even when YAML configuration is invalid', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_doctor_');
    addTearDown(() => temp.delete(recursive: true));
    final config = File('${temp.path}/broken.yaml');
    await config.writeAsString('storage: [this is not valid: yaml');

    final runtime = await TikoRuntime.create(configPath: config.path, allowInvalidConfig: true);
    addTearDown(runtime.approvals.close);
    addTearDown(runtime.events.close);

    final checks = await runtime.doctor();
    final names = checks.map((check) => check.name).toSet();

    expect(checks.any((check) => check.name.startsWith('config ')), isTrue);
    expect(names, containsAll([
      'resource_profile',
      'ram',
      'disk',
      'termux',
      'sqlite_native',
      'network',
      'offline_queue',
      'workspace',
      'data_dir',
      'memory',
      'sandbox',
    ]));
  });
}
