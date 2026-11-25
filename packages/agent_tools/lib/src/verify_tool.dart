import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'path_safety.dart';
import 'sandbox.dart';

/// Fase B — `verify_project`: jalankan perintah verifikasi (build/test/
/// analyze) sebagai gate objektif loop coding/debugging. Bukan tebakan
/// model: hasilnya exit code nyata + output (tail) yang menjadi umpan balik.
///
/// Keamanan setara `shell`:
/// - metacharacter shell dilarang (tanpa pipe/redirect/`&&`) — perintah
///   verifikasi memang satu perintah langsung;
/// - argumen path-like divalidasi PathSafety (symlink-aware, fail-closed);
/// - jalur eksekusi via [SandboxRunner] yang sama (jail workspace).
class VerifyOutcome {
  const VerifyOutcome({
    required this.ok,
    required this.exitCode,
    required this.output,
    this.command,
    this.processError,
  });

  final bool ok;
  final int exitCode;
  final String output;
  final String? command;

  /// Terisi bila proses tidak bisa dijalankan sama sekali (toolchain
  /// tidak ada di PATH) — dipakai mode `auto` untuk lompat ke kandidat
  /// berikutnya, alih-alih menganggap party verifikasi gagal.
  final ProcessException? processError;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'exit_code': exitCode,
        if (command != null) 'command': command,
        'output': output,
      };
}

/// S19-C — deteksi toolchain verifikasi dari manifest project di [root].
/// Data-driven (menambah bahasa = menambah entri), urutan = prioritas.
/// Perintah dipilih yang pasti read-only/analyze (bukan build penuh) dan
/// tanpa metachar (kontrak [runVerification]).
List<String> detectVerifyCandidates(String root) {
  final out = <String>[];
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    final usesFlutter =
        content.contains('sdk: flutter') || content.contains('sdk: flutter ');
    out.add(usesFlutter ? 'flutter analyze' : 'dart analyze');
  }
  if (File(p.join(root, 'go.mod')).existsSync()) out.add('go vet ./...');
  if (File(p.join(root, 'Cargo.toml')).existsSync()) out.add('cargo check');
  if (File(p.join(root, 'tsconfig.json')).existsSync()) {
    out.add('npx tsc --noEmit');
  }
  return out;
}

/// Metacharacter yang dilarang — kontrak sama dengan `ShellTool`.
const kVerifyForbiddenMetachars = [
  ';', '&&', '||', '|', '`', r'$(', '>', '<', '\n', '\r', '\t',
];

/// Jalankan satu perintah verifikasi di dalam workspace. Tidak pernah
/// throw: command invalid / spawn gagal menghasilkan [VerifyOutcome] dengan
/// `ok: false` dan penanda jujur.
///
/// [unsandboxedFallback]: bila tidak ada OS sandbox (SandboxKind.none
/// fail-closed), jalankan via `Process.run(argv, workingDirectory: root)` —
/// argv array TANPA shell (tidak ada interpretasi metachar), cwd dijail ke
/// workspace, dan PathSafety tetap memvalidasi argumen path-like. Ini
/// lebih ketat dari `sh -c` dan diperlukan agar gate verifikasi tetap
/// jalan di host tanpa docker/bwrap (mis. laptop user / CI).
Future<VerifyOutcome> runVerification(
  String cmd, {
  required String workspacePath,
  SandboxRunner? sandbox,
  bool unsandboxedFallback = true,
  Duration timeout = const Duration(seconds: 180),
  int maxOutputChars = 8000,
}) async {
  final trimmed = cmd.trim();
  for (final m in kVerifyForbiddenMetachars) {
    if (trimmed.contains(m)) {
      return VerifyOutcome(
        ok: false,
        exitCode: -1,
        output: 'error: Metacharacter shell dilarang: $m',
        command: cmd,
      );
    }
  }
  final parts =
      trimmed.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) {
    return const VerifyOutcome(
      ok: false,
      exitCode: -1,
      output: 'error: perintah verifikasi kosong',
    );
  }
  final root = p.normalize(Directory(workspacePath).absolute.path);
  for (final part in parts.skip(1)) {
    final value = part.startsWith('-') && part.contains('=')
        ? part.substring(part.indexOf('=') + 1)
        : part.startsWith('-')
            ? null
            : part;
    if (value == null || value.isEmpty) continue;
    final resolved = PathSafety.resolveInRoot(root, value);
    if (resolved == null) {
      return VerifyOutcome(
        ok: false,
        exitCode: -1,
        output: 'error: path argumen di luar workspace: $part',
        command: cmd,
      );
    }
  }
  final effectiveSandbox = sandbox ??
      SandboxRunner(kind: SandboxKind.none, workspacePath: root);
  final unsandboxed = unsandboxedFallback && effectiveSandbox.kind == SandboxKind.none;
  try {
    final ProcessResult result = unsandboxed
        ? await (Process.run(parts.first, parts.sublist(1),
                    workingDirectory: root)
                .timeout(timeout))
        : await effectiveSandbox.run(parts, timeout: timeout);
    final buf = StringBuffer();
    final stdoutText = result.stdout as String? ?? '';
    final stderrText = result.stderr as String? ?? '';
    if (stdoutText.isNotEmpty) buf.writeln(stdoutText);
    if (stderrText.isNotEmpty) buf.writeln('--- stderr ---\n$stderrText');
    var output = buf.toString().trim();
    if (output.length > maxOutputChars) {
      output =
          '${output.substring(output.length - maxOutputChars)}\n…[dipotong depan]';
    }
    return VerifyOutcome(
      ok: result.exitCode == 0,
      exitCode: result.exitCode,
      output: output.isEmpty ? '(tanpa output)' : output,
      command: cmd,
    );
  } catch (e) {
    final processError = e is ProcessException ? e : null;
    return VerifyOutcome(
      ok: false,
      exitCode: -1,
      output: processError != null
          ? 'error: toolchain tidak tersedia (${processError.executable})'
          : 'error: perintah verifikasi gagal jalan ($e)',
      command: cmd,
      processError: processError,
    );
  }
}

class VerifyProjectTool implements Tool {
  VerifyProjectTool({required this.workspaceRoot, this.sandbox,
      this.unsandboxedFallback = true});

  final String workspaceRoot;
  final SandboxRunner? sandbox;

  /// Bila tidak ada OS sandbox: boleh argv-exec tanpa shell (lihat
  /// [runVerification]). Default true agar gate verifikasi tersedia
  /// di host tanpa docker/bwrap; set false untuk mengetat.
  final bool unsandboxedFallback;

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'verify_project',
        description:
            'Jalankan perintah verifikasi (build/test/analyze) di workspace '
            'dan laporkan exit code + output. Dipakai untuk membuktikan '
            'perbaikan; bukan asumsi.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'cmd': {
              'type': 'string',
              'description':
                  'Perintah verifikasi, mis. "dart analyze" atau "dart test". '
                  'Tanpa pipe/redirect/&&. Kosongkan bila auto=true.',
            },
            'auto': {
              'type': 'boolean',
              'description':
                  'S19-C: deteksi toolchain dari manifest project (pubspec/'
                  'go.mod/Cargo.toml/tsconfig) lalu jalankan kandidat verifikasi '
                  'nyata yang pertama tersedia. Diabaikan bila cmd diisi.',
            },
            'timeout_sec': {
              'type': 'integer',
              'description': 'Batas waktu 15..600 detik (default 180).',
            },
          },
        },
        risk: 'high',
        timeoutSec: 600,
        maxOutputChars: 12000,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final cmd = (args['cmd'] as String?)?.trim() ?? '';
    final timeoutSec = (args['timeout_sec'] as num?)?.toInt();
    final timeout = Duration(seconds: (timeoutSec ?? 180).clamp(15, 600));
    if (cmd.isEmpty) {
      final auto = args['auto'] == true;
      if (!auto) {
        return const ToolResult(
          callId: '',
          content: 'error: cmd kosong (isi cmd atau auto=true)',
          isError: true,
        );
      }
      final root = p.normalize(Directory(ctx.workspacePath).absolute.path);
      final candidates = detectVerifyCandidates(root);
      if (candidates.isEmpty) {
        return const ToolResult(
          callId: '',
          content:
              'tidak ada manifest verifikasi dikenali di root workspace '
              '(didukung: pubspec.yaml, go.mod, Cargo.toml, tsconfig.json)',
          isError: true,
        );
      }
      for (final candidate in candidates) {
        final outcome = await runVerification(
          candidate,
          workspacePath: ctx.workspacePath,
          sandbox: sandbox,
          unsandboxedFallback: unsandboxedFallback,
          timeout: timeout,
          maxOutputChars: 8000,
        );
        if (outcome.processError != null) continue;
        return ToolResult(
          callId: '',
          content: [
            '[auto] kandidat: $candidate',
            outcome.ok ? 'VERIFIKASI OK' : 'VERIFIKASI GAGAL',
            'exit: ${outcome.exitCode}',
            '--- output ---',
            outcome.output,
          ].join('\n'),
          isError: !outcome.ok,
        );
      }
      return ToolResult(
        callId: '',
        content:
            'tidak ada toolchain verifikasi tersedia di PATH (kandidat: '
            '${candidates.join(', ')}) — jalankan `tiko doctor --fix` atau '
            'pasang manual, lalu ulangi',
        isError: true,
      );
    }
    final outcome = await runVerification(
      cmd,
      workspacePath: ctx.workspacePath,
      sandbox: sandbox,
      unsandboxedFallback: unsandboxedFallback,
      timeout: timeout,
      maxOutputChars: 8000,
    );
    return ToolResult(
      callId: '',
      content: [
        outcome.ok ? 'VERIFIKASI OK' : 'VERIFIKASI GAGAL',
        'exit: ${outcome.exitCode}',
        '--- output ---',
        outcome.output,
      ].join('\n'),
      isError: !outcome.ok,
    );
  }
}
