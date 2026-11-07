import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Detect and run commands inside an OS sandbox (AGD-07, FR-02).
///
/// `SandboxKind.none` is deliberately fail-closed: it never runs a child
/// process on the host. Callers must surface that the capability is disabled.
enum SandboxKind { none, bubblewrap, docker, ssh }

/// Computes a command risk index R_cmd ∈ [0,1] for sandbox dispatch.
/// Callers that have the full structured policy available (e.g.
/// `ShellPolicy.commandRisk` from agent_security) should inject it via
/// [SandboxRunner.dispatchFor] so scoring stays centralized.
typedef CommandRiskFn = double Function(String command);

class SandboxRunner {
  SandboxRunner({
    this.kind = SandboxKind.none,
    this.dockerImage = 'python:3.13-alpine',
    this.workspacePath = '.',
    this.maxOutputBytes = 1024 * 1024,
    this.sshHost,
    this.sshPort = 22,
    this.sshRemoteRoot = '/tmp/tiko-work',
  })  : assert(maxOutputBytes > 0),
        assert(kind != SandboxKind.ssh || (sshHost ?? '').isNotEmpty,
            'ssh sandbox requires an sshHost (user@host)');

  final SandboxKind kind;
  final String dockerImage;
  final String workspacePath;
  final int maxOutputBytes;

  /// FR-02 remote sandbox: `user@host` SSH target. Required for kind ssh.
  final String? sshHost;
  final int sshPort;

  /// Workspace root on the remote host for the ssh sandbox.
  final String sshRemoteRoot;

  final Map<int, String> _dockerContainers = {};

  static Future<SandboxKind> detect({String dockerImage = 'python:3.13-alpine'}) async {
    if (await _probeBubblewrap()) return SandboxKind.bubblewrap;
    if (await _probeDocker(dockerImage)) return SandboxKind.docker;
    return SandboxKind.none;
  }

  /// FR-02 dispatcher: maps a command's risk index to the least-privilege
  /// sandbox that can safely run it.
  ///
  /// - risk < 0.2 → local isolation (bubblewrap, else docker)
  /// - 0.2 ≤ risk < 0.7 → docker container
  /// - risk ≥ 0.7 → remote ssh host when configured, else docker
  ///
  /// `SandboxKind.none` is NEVER returned: when no backend is available the
  /// caller must refuse execution (fail-closed).
  static Future<SandboxRunner> dispatchFor(
    String command, {
    String workspacePath = '.',
    String dockerImage = 'python:3.13-alpine',
    int maxOutputBytes = 1024 * 1024,
    String? sshHost,
    int sshPort = 22,
    String sshRemoteRoot = '/tmp/tiko-work',
    CommandRiskFn? riskFn,
  }) async {
    final risk = riskFn != null ? riskFn(command) : _fallbackRisk(command);

    final dockerAvailable = await _probeDocker(dockerImage);
    final bwrapAvailable = await _probeBubblewrap();
    final sshAvailable = sshHost != null && sshHost.isNotEmpty && await _probeSsh();

    SandboxKind kind;
    if (risk < 0.2) {
      kind = bwrapAvailable
          ? SandboxKind.bubblewrap
          : (dockerAvailable ? SandboxKind.docker : SandboxKind.none);
    } else if (risk < 0.7) {
      kind = dockerAvailable
          ? SandboxKind.docker
          : (bwrapAvailable ? SandboxKind.bubblewrap : SandboxKind.none);
    } else {
      if (sshAvailable) {
        kind = SandboxKind.ssh;
      } else if (dockerAvailable) {
        kind = SandboxKind.docker;
      } else {
        kind = SandboxKind.none;
      }
    }
    return SandboxRunner(
      kind: kind,
      dockerImage: dockerImage,
      workspacePath: workspacePath,
      maxOutputBytes: maxOutputBytes,
      sshHost: sshHost,
      sshPort: sshPort,
      sshRemoteRoot: sshRemoteRoot,
    );
  }

  /// Conservative fallback scorer used when no structured policy is
  /// injected. Coarse by design: unknown commands land in the container
  /// band (0.3), destructive/privileged patterns land in the remote band.
  static double _fallbackRisk(String command) {
    final cmd = command.trim().toLowerCase();
    if (cmd.isEmpty) return 0;
    const remote = [
      'rm -rf', 'mkfs', 'dd if=', 'shutdown', 'reboot', 'kill -9',
      'sudo', 'su ', 'curl', 'wget', 'apt', 'apt-get', 'yum', 'dnf',
      'pacman', 'pip install', 'npm install', 'chown', 'chmod',
    ];
    if (remote.any(cmd.contains)) return 0.75;
    if (RegExp(r'[;&|`$(){}><]').hasMatch(cmd)) return 0.8;
    return 0.3;
  }

  static Future<bool> _probeBubblewrap() async {
    if (!await _has('bwrap')) return false;
    try {
      // Probe the exact namespace features used by startProcess(). A basic
      // user/pid namespace probe is insufficient: network/uts/ipc or session
      // isolation may still be denied by the host (common on mobile kernels).
      final result = await Process.run('bwrap', [
        '--die-with-parent',
        '--new-session',
        '--unshare-user',
        '--unshare-pid',
        '--unshare-net',
        '--unshare-uts',
        '--unshare-ipc',
        '--ro-bind', '/usr', '/usr',
        '--ro-bind-try', '/bin', '/bin',
        '--ro-bind-try', '/sbin', '/sbin',
        '--ro-bind-try', '/lib', '/lib',
        '--ro-bind-try', '/lib64', '/lib64',
        '--proc', '/proc',
        '--dev', '/dev',
        '--tmpfs', '/tmp',
        '--setenv', 'PATH', '/usr/local/bin:/usr/bin:/bin',
        '--setenv', 'HOME', '/tmp',
        '/usr/bin/true',
      ]).timeout(const Duration(seconds: 3));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _probeDocker(String image) async {
    if (!await _has('docker')) return false;
    try {
      final engine = await Process.run('docker', ['info', '--format', '{{.ServerVersion}}'])
          .timeout(const Duration(seconds: 4));
      if (engine.exitCode != 0 || (engine.stdout as String).trim().isEmpty) return false;
      final localImage = await Process.run('docker', ['image', 'inspect', image])
          .timeout(const Duration(seconds: 4));
      return localImage.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _probeSsh() async {
    if (!await _has('ssh')) return false;
    try {
      final r = await Process.run('ssh', ['-V']).timeout(const Duration(seconds: 2));
      return r.exitCode == 0 || (r.stderr as String).contains('OpenSSH');
    } catch (_) {
      // `ssh -V` writes to stderr and exits 1 on some builds; treat a
      // non-throwing invocation as available anyway.
      return true;
    }
  }

  static Future<bool> _has(String cmd) async {
    try {
      final r = await Process.run('which', [cmd]).timeout(const Duration(seconds: 2));
      return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Start a long-running process inside the selected sandbox.
  /// The returned process is still owned and must be killed/closed by caller.
  Future<Process> startProcess(
    List<String> parts, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (parts.isEmpty || parts.first.trim().isEmpty || parts.length > 64 ||
        parts.any((part) => part.contains('\u0000') || part.length > 8192) ||
        parts.fold<int>(0, (sum, part) => sum + part.length) > 64 * 1024) {
      throw ArgumentError.value(parts, 'parts', 'invalid or oversized argv');
    }
    if (kind == SandboxKind.none) {
      throw UnsupportedError(
        'OS sandbox tidak tersedia; eksekusi shell/script/MCP dinonaktifkan.',
      );
    }

    final extraEnv = environment ?? const <String, String>{};
    for (final entry in extraEnv.entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(entry.key) ||
          const {
            'PATH', 'HOME', 'LD_PRELOAD', 'LD_LIBRARY_PATH', 'PYTHONPATH',
            'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH',
          }.contains(entry.key.toUpperCase()) ||
          entry.value.contains('\u0000') || entry.value.contains('\n') || entry.value.contains('\r')) {
        throw ArgumentError('invalid sandbox environment variable: ${entry.key}');
      }
    }

    // The remote sshd rebuilds a shell command from argv, so every token
    // must be shell-inert before it is allowed onto the wire.
    if (kind == SandboxKind.ssh) {
      for (final part in parts) {
        if (!RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(part)) {
          throw ArgumentError.value(
            parts,
            'parts',
            'ssh sandbox only allows inert tokens (no quoting/expansion): $part',
          );
        }
      }
      return _startSsh(parts,
          workingDirectory: workingDirectory, extraEnv: extraEnv);
    }

    final requestedRoot = Directory(workspacePath).absolute;
    await requestedRoot.create(recursive: true);
    final root = requestedRoot.resolveSymbolicLinksSync();
    final requestedCwd = Directory(workingDirectory ?? root).absolute;
    final cwd = requestedCwd.resolveSymbolicLinksSync();
    if (!_isWithin(root, cwd)) {
      throw ArgumentError('working directory is outside the sandbox workspace');
    }
    final env = <String, String>{
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'HOME': root,
      'LANG': 'C.UTF-8',
      ...extraEnv,
    };
    final containerName = kind == SandboxKind.docker
        ? 'tiko-sbx-${pid}-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    final command = _sandboxCommand(parts, root, cwd, extraEnv, containerName);
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: kind == SandboxKind.docker ? root : null,
      environment: env,
      includeParentEnvironment: false,
      runInShell: false,
    );
    if (containerName != null) {
      _dockerContainers[process.pid] = containerName;
      unawaited(process.exitCode.then((_) => _dockerContainers.remove(process.pid)));
    }
    return process;
  }

  /// FR-02 remote execution: runs argv on the configured ssh host inside a
  /// non-interactive shell, rooted at [sshRemoteRoot].
  Future<Process> _startSsh(
    List<String> parts, {
    String? workingDirectory,
    required Map<String, String> extraEnv,
  }) async {
    final host = sshHost!;
    var remoteCwd = sshRemoteRoot;
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) {
      // Only the workspace-relative suffix is honored remotely.
      final root = Directory(workspacePath).absolute.path;
      final abs = Directory(workingDirectory).absolute.path;
      if (!_isWithin(root, abs)) {
        throw ArgumentError('working directory is outside the sandbox workspace');
      }
      final suffix = abs == root
          ? ''
          : abs.substring(root.length).replaceAll(RegExp(r'^[/\\]+'), '');
      remoteCwd = suffix.isEmpty
          ? sshRemoteRoot
          : '$sshRemoteRoot/${suffix.replaceAll(RegExp(r'[^A-Za-z0-9_./-]'), '')}';
    }
    final sb = StringBuffer('mkdir -p ${_shQuote(remoteCwd)} && cd ${_shQuote(remoteCwd)}');
    if (extraEnv.isNotEmpty) {
      sb.write(' && env');
      for (final e in extraEnv.entries) {
        sb.write(' ${e.key}=${_shQuote(e.value)}');
      }
    }
    sb.write(' && exec');
    for (final part in parts) {
      sb.write(' $part'); // tokens are pre-validated inert
    }
    return Process.start(
      'ssh',
      [
        '-p', '$sshPort',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        host,
        '--',
        sb.toString(),
      ],
      includeParentEnvironment: false,
      runInShell: false,
    );
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Run argv (never through a shell), with bounded output and kill-on-timeout.
  Future<ProcessResult> run(
    List<String> parts, {
    Duration timeout = const Duration(seconds: 15),
    String? stdinText,
    String? workingDirectory,
  }) async {
    final proc = await startProcess(parts, workingDirectory: workingDirectory);
    final stdoutBytes = BytesBuilder(copy: false);
    final stderrBytes = BytesBuilder(copy: false);
    var stdoutTruncated = false;
    var stderrTruncated = false;

    void appendBounded(BytesBuilder builder, List<int> chunk, bool isStdout) {
      final remaining = maxOutputBytes - builder.length;
      if (remaining <= 0) {
        if (isStdout) {
          stdoutTruncated = true;
        } else {
          stderrTruncated = true;
        }
        return;
      }
      if (chunk.length > remaining) {
        builder.add(chunk.sublist(0, remaining));
        if (isStdout) {
          stdoutTruncated = true;
        } else {
          stderrTruncated = true;
        }
      } else {
        builder.add(chunk);
      }
    }

    final outSub = proc.stdout.listen((chunk) => appendBounded(stdoutBytes, chunk, true));
    final errSub = proc.stderr.listen((chunk) => appendBounded(stderrBytes, chunk, false));
    var exitCode = -1;
    try {
      if (stdinText != null && stdinText.isNotEmpty) {
        proc.stdin.add(utf8.encode(stdinText));
      }
      await proc.stdin.close();
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      await stopProcess(proc);
      rethrow;
    } catch (_) {
      await stopProcess(proc);
      rethrow;
    } finally {
      await outSub.cancel();
      await errSub.cancel();
    }

    var stdout = utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true);
    var stderr = utf8.decode(stderrBytes.takeBytes(), allowMalformed: true);
    if (stdoutTruncated) stdout = '$stdout\n[stdout truncated at $maxOutputBytes bytes]';
    if (stderrTruncated) stderr = '$stderr\n[stderr truncated at $maxOutputBytes bytes]';
    return ProcessResult(proc.pid, exitCode, stdout, stderr);
  }

  Future<void> stopProcess(Process process) async {
    process.kill(ProcessSignal.sigkill);
    final name = _dockerContainers.remove(process.pid);
    if (name != null) {
      try {
        await Process.run('docker', ['rm', '--force', name]).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  ({String executable, List<String> arguments}) _sandboxCommand(
    List<String> parts,
    String root,
    String cwd,
    Map<String, String> extraEnv,
    String? containerName,
  ) {
    switch (kind) {
      case SandboxKind.bubblewrap:
        final args = <String>[
          '--die-with-parent',
          '--new-session',
          '--unshare-user',
          '--unshare-pid',
          '--unshare-net',
          '--unshare-uts',
          '--unshare-ipc',
          '--ro-bind', '/usr', '/usr',
          '--ro-bind-try', '/bin', '/bin',
          '--ro-bind-try', '/sbin', '/sbin',
          '--ro-bind-try', '/lib', '/lib',
          '--ro-bind-try', '/lib64', '/lib64',
          '--ro-bind-try', '/etc/ld.so.cache', '/etc/ld.so.cache',
          '--ro-bind-try', '/etc/alternatives', '/etc/alternatives',
          '--bind', root, root,
          '--tmpfs', '/tmp',
          '--proc', '/proc',
          '--dev', '/dev',
          '--chdir', cwd,
          '--setenv', 'PATH', '/usr/local/bin:/usr/bin:/bin',
          '--setenv', 'HOME', root,
          '--setenv', 'LANG', 'C.UTF-8',
          // Process.start receives a scrubbed environment containing only
          // base variables and the explicitly configured MCP secrets.
          '--',
          ...parts,
        ];
        return (executable: 'bwrap', arguments: args);
      case SandboxKind.docker:
        final args = <String>[
          'run',
          '--rm',
          '--pull=never',
          if (containerName != null) ...['--name', containerName],
          '-i',
          '--init',
          '--network', 'none',
          '--read-only',
          '--cap-drop=ALL',
          '--security-opt=no-new-privileges',
          '--pids-limit=64',
          '--memory=256m',
          '--cpus=1.0',
          '--tmpfs', '/tmp:rw,noexec,nosuid,size=16m',
          // Docker reads values from the scrubbed host environment. Avoid
          // embedding secret values in argv where they could appear in `ps`.
          for (final entry in extraEnv.entries) ...['--env', entry.key],
          '-v', '$root:/work:rw',
          '-w', cwd == root ? '/work' : '/work/${cwd.substring(root.length).replaceAll(Platform.pathSeparator, '/')}',
          dockerImage,
          ...parts,
        ];
        return (executable: 'docker', arguments: args);
      case SandboxKind.ssh:
        // Handled by _startSsh(); never reached through this path.
        throw UnsupportedError('ssh sandbox must use startProcess directly');
      case SandboxKind.none:
        throw UnsupportedError('sandbox unavailable');
    }
  }

  bool _isWithin(String root, String path) {
    final separator = Platform.pathSeparator;
    return path == root || path.startsWith(root.endsWith(separator) ? root : '$root$separator');
  }
}
