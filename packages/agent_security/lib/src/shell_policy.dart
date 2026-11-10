/// Structured shell policy: match full argv tokens, reject metacharacters.
///
/// Also provides the command risk index `R_cmd` (FR-02 dispatcher) used by
/// the sandbox router: R_cmd < 0.2 → local execution is acceptable,
/// 0.2–0.7 → container sandbox, ≥ 0.7 → remote/isolated sandbox only.
class ShellPolicy {
  ShellPolicy({
    this.allowlist = const [
      ['ls'],
      ['pwd'],
      ['echo'],
      ['git', 'status'],
      ['git', 'diff'],
      ['git', 'log'],
    ],
  });

  final List<List<String>> allowlist;

  static final _meta =
      RegExp(r'[;&|`$(){}><*?~\\\[\]\n]|\$\{|\$\(');

  /// Returns null if allowed, else deny reason.
  String? check(String command) {
    final cmd = command.trim();
    if (cmd.isEmpty) return 'empty command';
    if (_meta.hasMatch(cmd)) {
      return 'metacharacter / expansion not allowed';
    }
    final parts = cmd.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'empty argv';

    for (final allowed in allowlist) {
      if (parts.length < allowed.length) continue;
      var match = true;
      for (var i = 0; i < allowed.length; i++) {
        if (parts[i] != allowed[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        // exact length or only trailing simple args without meta
        return null;
      }
    }
    return 'command not in structured allowlist: ${parts.take(3).join(' ')}';
  }

  static List<List<String>> fromStringList(List<String> entries) {
    return entries
        .map((e) => e.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  // ---------------------------------------------------------------------
  // R_cmd command risk index (PRD §FR-02 dispatch algorithm).
  // ---------------------------------------------------------------------

  /// Patterns that are destructive even without metacharacters. Their mere
  /// presence pushes a command deep into "remote sandbox only" territory.
  static const _destructivePatterns = [
    'rm -rf',
    'rm -fr',
    'mkfs',
    'dd if=',
    'shred ',
    'shutdown',
    'reboot',
    'kill -9',
    'killall',
    'chmod -r 777',
    'chmod 777',
    'chown -r',
    'mkswap',
    'wipefs',
    '>/dev/sd',
    'truncate -s',
    'drop table',
    'drop database',
    'del /f',
    'rd /s',
    'format ',
    ':(){ :|:& };:',
  ];

  static const _privilegeEscalations = [
    'sudo',
    'su -',
    'su root',
    'doas',
    'pkexec',
    'runuser',
  ];

  /// Piping remote content straight into an interpreter = supply-chain risk.
  static const _pipeToShellPatterns = [
    'curl',
    'wget',
  ];

  static const _interpreterSuffixes = [
    '| sh',
    '|sh',
    '| bash',
    '|bash',
    '| python',
    '|python',
    '| python3',
    '|python3',
    '-o- |',
    '| zsh',
  ];

  static const _packageManagers = [
    'apt',
    'apt-get',
    'yum',
    'dnf',
    'pacman',
    'brew',
    'pip install',
    'pip3 install',
    'npm install',
    'npx',
    'cargo install',
    'gem install',
    'snap install',
    'flutter pub',
    'dart pub',
  ];

  /// Patterns indicating read/write access outside an obvious workspace,
  /// network mutation, or daemon control.
  static const _sensitiveTargets = [
    '/etc/',
    '/usr/',
    '/var/',
    '/boot',
    'crontab',
    'systemctl',
    'service ',
    'iptables',
    'ufw',
    'nc ',
    'netcat',
    'registry',
    'docker rm',
    'docker kill',
  ];

  /// Computes the risk index R_cmd ∈ [0, 1] for a command string.
  ///
  /// Scoring is additive and saturating:
  /// - base 0.05 for any non-empty command
  /// - +0.55 for each destructive pattern (capped once)
  /// - +0.30 for privilege escalation
  /// - +0.40 for curl/wget piped into an interpreter
  /// - +0.15 for package-manager mutation
  /// - +0.10 for sensitive system targets
  /// - commands containing metacharacters that [check] would reject are
  ///   always scored ≥ 0.8, because they must never run locally.
  double commandRisk(String command) {
    final cmd = command.trim().toLowerCase();
    if (cmd.isEmpty) return 0;

    if (_meta.hasMatch(cmd)) return 0.8;

    var score = 0.05;

    if (_destructivePatterns.any(cmd.contains)) score += 0.55;
    if (_privilegeEscalations.any(cmd.contains)) score += 0.30;

    final fetches = _pipeToShellPatterns.any(cmd.contains);
    final interprets = _interpreterSuffixes.any(cmd.contains);
    if (fetches && interprets) score += 0.40;

    if (_packageManagers.any(cmd.contains)) score += 0.15;
    if (_sensitiveTargets.any(cmd.contains)) score += 0.10;

    // Multi-command strings (even if check() allows each token) are more
    // opaque than single commands.
    if (cmd.split(RegExp(r'\s+')).length > 8) score += 0.05;

    if (score > 1) score = 1;
    return score;
  }
}
