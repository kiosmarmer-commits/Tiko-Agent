import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  group('Sandbox dispatcher (P2-5)', () {
    test('SandboxRunner with none kind throws UnsupportedError on run',
        () {
      final runner = SandboxRunner(kind: SandboxKind.none);
      
      // Runner with none should throw UnsupportedError on execution
      expect(
        () => runner.run(['echo', 'hello']),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('SandboxRunner with none kind throws UnsupportedError on startProcess',
        () {
      final runner = SandboxRunner(kind: SandboxKind.none);
      
      expect(
        () => runner.startProcess(['echo', 'hello']),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('SandboxRunner with none kind has correct message in UnsupportedError',
        () {
      final runner = SandboxRunner(kind: SandboxKind.none);
      
      try {
        runner.run(['echo', 'hello']);
        fail('Expected UnsupportedError to be thrown');
      } catch (e) {
        expect(e, isA<UnsupportedError>());
        expect(e.toString(), contains('OS sandbox tidak tersedia'));
      }
    });

    test('SandboxRunner with docker kind does not throw on construction',
        () {
      // Should be able to create a runner with docker kind
      final runner = SandboxRunner(kind: SandboxKind.docker);
      expect(runner.kind, SandboxKind.docker);
    });

    test('dispatchFor returns a SandboxRunner with valid kind',
        () async {
      // Test that dispatchFor returns a valid runner
      // Note: The actual kind depends on available backends in the test environment
      final runner = await SandboxRunner.dispatchFor('echo hello');
      
      // Should return a runner with some kind
      expect(runner.kind, isA<SandboxKind>());
      expect(runner, isA<SandboxRunner>());
    });
  });
}


