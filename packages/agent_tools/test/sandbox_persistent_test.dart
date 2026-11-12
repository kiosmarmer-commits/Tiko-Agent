import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  group('Persistent docker sandbox (P1-5)', () {
    test('dockerRunPersistentArgv: hardening lengkap + workspace mount', () {
      final argv = dockerRunPersistentArgv(
        container: 'tiko-sbx-persistent-1',
        root: '/tmp/ws',
        image: 'python:3.13-alpine',
      );
      expect(argv[0], 'run');
      expect(argv, contains('-d'));
      expect(argv, containsAll(['--name', 'tiko-sbx-persistent-1']));
      expect(argv, containsAll(['--network', 'none']));
      expect(argv, contains('--read-only'));
      expect(argv, contains('--cap-drop=ALL'));
      expect(argv, contains('--security-opt=no-new-privileges'));
      expect(argv, contains('--pids-limit=64'));
      expect(argv, contains('--memory=256m'));
      expect(argv, containsAll(['-v', '/tmp/ws:/work:rw']));
      expect(argv, containsAll(['-w', '/work']));
      expect(argv.last2(), ['sleep', '100000000']);
    });

    test('dockerExecArgv: cwd, env-by-key (tanpa nilai di argv), argv utuh',
        () {
      final argv = dockerExecArgv(
        container: 'c1',
        cwdInContainer: '/work/sub/dir',
        envKeys: ['MY_TOKEN'],
        parts: ['python3', '-c', 'print(1)'],
      );
      expect(argv.sublist(0, 4), ['exec', '-i', '-w', '/work/sub/dir']);
      expect(argv, containsAll(['-e', 'MY_TOKEN']));
      expect(argv.join(' '), isNot(contains('secret-value')),
          reason: 'nilai env tidak boleh masuk argv');
      expect(argv.sublist(argv.length - 3),
          ['python3', '-c', 'print(1)']);
      expect(argv[argv.length - 4], 'c1');
    });

    test('SandboxRunner menerima containerPersistent (default false)', () {
      expect(
        SandboxRunner(kind: SandboxKind.none).containerPersistent,
        isFalse,
      );
      expect(
        SandboxRunner(kind: SandboxKind.docker, containerPersistent: true)
            .containerPersistent,
        isTrue,
      );
    });

    test('dispose() tanpa container: no-op tanpa error', () async {
      final runner = SandboxRunner(kind: SandboxKind.none);
      await runner.dispose();
    });
  });
}

extension _Last2 on List<String> {
  List<String> last2() => sublist(length - 2);
}
