import 'dart:typed_data';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('Porcupine detector delegates to injected native processor', () async {
    var calls = 0;
    final detector = PorcupineWakeWordDetector(
      wakeWordPath: 'model.ppn',
      nativeProcessor: (Uint8List _) {
        calls++;
        return true;
      },
    );
    var detected = 0;
    detector.setOnDetected(() => detected++);
    await detector.start();
    expect(detector.processAudio(Uint8List.fromList([0])), isTrue);
    expect(calls, 1);
    expect(detected, 1);
    await detector.stop();
  });

  test(
    'openWakeWord does not use energy fallback with native processor',
    () async {
      final detector = OpenWakeWordDetector(
        modelPath: 'model.tflite',
        nativeProcessor: (_) => false,
      );
      await detector.start();
      expect(
        detector.processAudio(Uint8List.fromList(List.filled(128, 255))),
        isFalse,
      );
      await detector.stop();
    },
  );
}
