import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('subprocess listener memicu onDetected per baris stdout detector',
      () async {
    var detected = 0;
    final listener = SubprocessHotwordListener(
      command: const ['sh', '-c', 'echo hey; echo tiko'],
    );
    await listener.start(() => detected++);
    expect(listener.isListening, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(detected, greaterThanOrEqualTo(2));
    await listener.stop();
    expect(listener.isListening, isFalse);
  });

  test('start() idempotent tidak menyubproses ganda', () async {
    final listener = SubprocessHotwordListener(
      command: const ['sh', '-c', 'echo hey; sleep 30'],
    );
    await listener.start(() {});
    final first = listener.process;
    await listener.start(() {});
    expect(identical(first, listener.process), isTrue);
    await listener.stop();
  });

  test('stop() menghentikan proses dan melepas listening', () async {
    final listener = SubprocessHotwordListener(
      command: const ['sh', '-c', 'sleep 30'],
    );
    await listener.start(() {});
    final process = listener.process!;
    await listener.stop();
    expect(listener.process, isNull);
    expect(listener.isListening, isFalse);
    final code = await process.exitCode;
    expect(code, isNot(equals(0)));
  });

  test('command tidak valid fail-closed: gagal start tanpa deteksi palsu',
      () {
    final listener = SubprocessHotwordListener(
      command: const ['tiko-detektor-tidak-ada-xyz'],
    );
    expect(listener.start(() {}), throwsA(isA<ProcessException>()));
    expect(listener.isListening, isFalse);
  });

  test('factory memilih listener proc eksternal bila command diberi', () async {
    final listener = WakeWordDetectorFactory.create(
      subprocessCommand: const ['sh', '-c', 'echo hey; sleep 30'],
      porcupinePath: 'model.ppn',
    );
    expect(listener, isA<SubprocessHotwordListener>());
    expect(listener.name, contains('subprocess:'));
    await listener.stop();
  });

  test('factory tanpa command tetap jatuh ke keyword spotter', () {
    final listener = WakeWordDetectorFactory.create();
    expect(listener, isNot(isA<SubprocessHotwordListener>()));
  });
}
