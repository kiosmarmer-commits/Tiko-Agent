import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('ResourceMonitor', () {
    test('snapshot has cpu count and serializes', () {
      final snapshot = ResourceMonitor.snapshot();
      expect(snapshot.cpuCount, greaterThan(0));
      expect(snapshot.toJson()['cpu_count'], snapshot.cpuCount);
      // rss/load may be null on non-Linux; types stay sound either way.
      expect(snapshot.rssMb == null || snapshot.rssMb! > 0, isTrue);
    });
  });

  group('PowerSaverGate', () {
    test('disabled saver always allows work', () {
      final gate = PowerSaverGate(pluggedIn: () => false);
      expect(gate.allowsWork(powerSaverEnabled: false), isTrue);
    });

    test('enabled saver blocks on battery', () {
      final gate = PowerSaverGate(pluggedIn: () => false);
      expect(gate.allowsWork(powerSaverEnabled: true), isFalse);
    });

    test('enabled saver allows when plugged', () {
      final gate = PowerSaverGate(pluggedIn: () => true);
      expect(gate.allowsWork(powerSaverEnabled: true), isTrue);
    });

    test('unknown power state treated as plugged (desktop never blocked)',
        () {
      final gate = PowerSaverGate(pluggedIn: () => null);
      expect(gate.allowsWork(powerSaverEnabled: true), isTrue);
    });
  });

}
