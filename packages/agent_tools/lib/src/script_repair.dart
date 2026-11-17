library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'sandbox.dart';

/// D3 — Loop koreksi-diri (self-correction) untuk script, eksperimental.
///
/// Saat script gagal dieksekusi (exit != 0 atau timeout), error (stdout/stderr)
/// dikirim ke [ScriptRepairAdvisor] (biasanya LLM) untuk menghasilkan patch
/// berupa **script lengkap pengganti**, lalu dicoba ulang — maksimal
/// [SelfCorrectingScriptRunner.maxAttempts] percobaan (default 3).
///
/// **Posisi yang jujur**:
/// - BUKAN sandbox Wasm (tidak ada dependency Wasm matang untuk Dart —
///   item roadmap ini dilaporkan blocked, bukan disembunyikan).
/// - BUKAN analisis AST sungguhan — koreksi dilakukan LLM atas teks error,
///   dengan validasi ketat atas hasil patch (fail-closed).
/// - Eksekusi tetap di OS sandbox yang sama dengan script tools; tanpa OS
///   sandbox, loop ini menolak jalan (tidak ada fallback host).
/// - Setiap percobaan tercatat di [ScriptRunReport] (audit trail).

/// Batas panjang script (char).
const int scriptRepairMaxScriptChars = 20000;

/// Exception ketika advisor gagal menghasilkan patch valid.
class ScriptRepairException implements Exception {
  ScriptRepairException(this.message);
  final String message;

  @override
  String toString() => 'ScriptRepairException: $message';
}

/// Input untuk advisor: konteks kegagalan satu percobaan.
class ScriptRepairInput {
  const ScriptRepairInput({
    required this.source,
    required this.entryFile,
    required this.command,
    required this.argsJson,
    required this.attempt,
    required this.maxAttempts,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final String source;
  final String entryFile;
  final List<String> command;
  final String argsJson;
  final int attempt;
  final int maxAttempts;
  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Sumber patch: implementasi produksi memakai LLM (lihat tiko_runtime),
/// test memakai fake.
abstract class ScriptRepairAdvisor {
  /// Mengembalikan **script lengkap pengganti**. Melempar
  /// [ScriptRepairException] bila tidak bisa menghasilkan patch.
  Future<String> proposePatch(ScriptRepairInput input);
}

/// Hasil satu eksekusi script.
class ScriptExecutionResult {
  const ScriptExecutionResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Fungsi eksekutor — produksi memakai [SandboxRunner.run]; test bisa
/// menyuntikkan executor sendiri (test seam, tidak pernah dipakai prod).
typedef ScriptExecutor = Future<ScriptExecutionResult> Function(
  List<String> command,
  String workingDirectory,
  String? stdinText,
  Duration timeout,
);

/// Satu baris audit trail.
class ScriptRepairAttempt {
  ScriptRepairAttempt({
    required this.attempt,
    required this.action,
    this.exitCode,
    this.errorExcerpt = '',
    required this.at,
  });

  final int attempt;
  final String action; // run | patch | abandon
  final int? exitCode;
  final String errorExcerpt;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'attempt': attempt,
        'action': action,
        if (exitCode != null) 'exit_code': exitCode,
        if (errorExcerpt.isNotEmpty) 'error': errorExcerpt,
        'at': at.toUtc().toIso8601String(),
      };
}

/// Hasil akhir loop: status, output terakhir, dan audit trail lengkap.
class ScriptRunReport {
  ScriptRunReport({
    required this.success,
    required this.output,
    required this.exitCode,
    required this.attempts,
    required this.finalSource,
    this.error,
  });

  final bool success;
  final String output;
  final int exitCode;
  final List<ScriptRepairAttempt> attempts;
  final String finalSource;
  final String? error;

  /// Ringkasan audit satu baris (untuk AuditLog resultSummary).
  String auditSummary() {
    final patches =
        attempts.where((a) => a.action == 'patch').length;
    return success
        ? 'sukses setelah ${attempts.length} percobaan ($patches patch)'
        : 'gagal setelah ${attempts.length} percobaan '
            '($patches patch): ${error ?? 'exit $exitCode'}';
  }
}

/// Loop eksekusi + perbaikan terbatas untuk satu script.
///
/// Tanpa [advisor], script tetap dijalankan sekali dan kegagalan dilaporkan
/// apa adanya (fail-closed — tidak ada "perbaikan" tanpa sumber patch).
class SelfCorrectingScriptRunner {
  SelfCorrectingScriptRunner({
    required this.sandbox,
    this.advisor,
    this.maxAttempts = 3,
    this.timeoutSec = 30,
    this.maxScriptChars = scriptRepairMaxScriptChars,
    this.maxOutputChars = 4000,
    DateTime Function()? clock,
    ScriptExecutor? executorOverride,
  })  : assert(maxAttempts >= 1 && maxAttempts <= 5),
        assert(timeoutSec >= 1 && timeoutSec <= 60),
        _clock = clock ?? DateTime.now,
        _executorOverride = executorOverride;

  final SandboxRunner sandbox;
  final ScriptRepairAdvisor? advisor;
  final int maxAttempts;
  final int timeoutSec;
  final int maxScriptChars;
  final int maxOutputChars;
  final DateTime Function() _clock;
  final ScriptExecutor? _executorOverride;

  static final RegExp _entryFilePattern = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');

  /// Menjalankan [source] sebagai [entryFile] dengan [command], memperbaiki
  /// via [advisor] saat gagal, maksimal [maxAttempts] eksekusi.
  Future<ScriptRunReport> run({
    required String source,
    String entryFile = 'run.py',
    List<String>? command,
    Map<String, dynamic>? args,
  }) async {
    // Validasi input (fail-closed).
    if (source.trim().isEmpty) {
      throw ArgumentError('source wajib diisi');
    }
    if (source.length > maxScriptChars) {
      throw ArgumentError('source melebihi $maxScriptChars karakter');
    }
    if (source.contains('\u0000')) {
      throw ArgumentError('source mengandung karakter null');
    }
    if (!_entryFilePattern.hasMatch(entryFile) ||
        entryFile.startsWith('.') ||
        entryFile.contains('..')) {
      throw ArgumentError('entry_file tidak valid: $entryFile');
    }
    final cmds = command ?? ['python3', entryFile];
    if (cmds.isEmpty || cmds.length > 32) {
      throw ArgumentError('command harus 1..32 argumen');
    }
    if (cmds.any((c) => c.trim().isEmpty || c.contains('\u0000')) ||
        cmds.fold<int>(0, (s, c) => s + c.length) > 8192) {
      throw ArgumentError('command mengandung argumen tidak valid');
    }
    final argsJson = args == null ? null : jsonEncode(args);

    // Fail-closed: tanpa OS sandbox dan tanpa executor override, menolak.
    final executor = _executorOverride;
    if (executor == null && sandbox.kind == SandboxKind.none) {
      throw StateError(
          'self-correction script dinonaktifkan: OS sandbox tidak tersedia');
    }

    final dir = await Directory.systemTemp.createTemp('tiko-selfheal-');
    try {
      final resolvedTemp = await Directory.systemTemp.resolveSymbolicLinks();
      final resolvedDir = await dir.resolveSymbolicLinks();
      if (!resolvedDir.startsWith('$resolvedTemp/')) {
        throw StateError('direktori kerja lolos dari temp root');
      }

      var current = source;
      final attempts = <ScriptRepairAttempt>[];

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final file = File('$resolvedDir/$entryFile');
        await file.writeAsString(current, flush: true);

        ScriptExecutionResult result;
        try {
          final procResult = await (executor ?? _sandboxExecutor())(
            cmds,
            resolvedDir,
            argsJson,
            Duration(seconds: timeoutSec),
          );
          result = procResult;
        } on TimeoutException {
          result = const ScriptExecutionResult(
            exitCode: -1,
            stdout: '',
            stderr: 'timeout',
          );
        }

        attempts.add(ScriptRepairAttempt(
          attempt: attempt,
          action: 'run',
          exitCode: result.exitCode,
          errorExcerpt:
              result.exitCode == 0 ? '' : _excerpt(result.stderr),
          at: _clock(),
        ));

        if (result.exitCode == 0) {
          return ScriptRunReport(
            success: true,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
          );
        }

        if (advisor == null || attempt == maxAttempts) {
          attempts.add(ScriptRepairAttempt(
            attempt: attempt,
            action: 'abandon',
            at: _clock(),
          ));
          return ScriptRunReport(
            success: false,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
            error: _limit(result.stderr.isEmpty
                ? 'exit ${result.exitCode}'
                : result.stderr),
          );
        }

        // Minta patch dari advisor.
        String patch;
        try {
          patch = await advisor!.proposePatch(ScriptRepairInput(
            source: current,
            entryFile: entryFile,
            command: cmds,
            argsJson: argsJson ?? '',
            attempt: attempt,
            maxAttempts: maxAttempts,
            exitCode: result.exitCode,
            stdout: _limit(result.stdout, 2000),
            stderr: _limit(result.stderr, 2000),
          ));
        } on ScriptRepairException catch (e) {
          attempts.add(ScriptRepairAttempt(
            attempt: attempt,
            action: 'abandon',
            errorExcerpt: 'advisor: ${e.message}',
            at: _clock(),
          ));
          return ScriptRunReport(
            success: false,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
            error: 'advisor gagal: ${e.message}',
          );
        }

        // Validasi patch (fail-closed): tidak kosong, dalam batas, berubah.
        if (patch.trim().isEmpty) {
          attempts.add(ScriptRepairAttempt(
            attempt: attempt,
            action: 'abandon',
            errorExcerpt: 'patch kosong',
            at: _clock(),
          ));
          return ScriptRunReport(
            success: false,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
            error: 'advisor menghasilkan patch kosong',
          );
        }
        if (patch.length > maxScriptChars || patch.contains('\u0000')) {
          attempts.add(ScriptRepairAttempt(
            attempt: attempt,
            action: 'abandon',
            errorExcerpt: 'patch melebihi batas',
            at: _clock(),
          ));
          return ScriptRunReport(
            success: false,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
            error: 'patch melebihi batas ukuran',
          );
        }
        if (patch == current) {
          attempts.add(ScriptRepairAttempt(
            attempt: attempt,
            action: 'abandon',
            errorExcerpt: 'patch identik (loop terdeteksi)',
            at: _clock(),
          ));
          return ScriptRunReport(
            success: false,
            output: _limit(result.stdout),
            exitCode: result.exitCode,
            attempts: List.unmodifiable(attempts),
            finalSource: current,
            error: 'advisor menghasilkan patch identik (tidak ada progres)',
          );
        }

        attempts.add(ScriptRepairAttempt(
          attempt: attempt,
          action: 'patch',
          at: _clock(),
        ));
        current = patch;
      }

      // Tidak terjangkau (loop selalu return), tapi compiler butuh return.
      throw StateError('loop koreksi keluar tanpa hasil');
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // best-effort cleanup
      }
    }
  }

  ScriptExecutor _sandboxExecutor() {
    final sb = sandbox;
    return (command, workingDirectory, stdinText, timeout) async {
      final result = await sb.run(
        command,
        workingDirectory: workingDirectory,
        stdinText: stdinText,
        timeout: timeout,
      );
      return ScriptExecutionResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    };
  }

  String _excerpt(String text) => _limit(text, 300);

  String _limit(String value, [int? max]) {
    final limit = max ?? maxOutputChars;
    if (value.length <= limit) return value;
    return '${value.substring(0, limit)}\n…[truncated]';
  }
}

/// Tool `script_selfheal` (D3, eksperimental) — jalankan script dengan loop
/// koreksi-diri terbatas. Risk **high**: mengeksekusi kode yang dihasilkan
/// LLM (walau tetap di dalam OS sandbox), sehingga butuh approval seperti
/// script tools lain.
class ScriptSelfHealTool implements Tool {
  ScriptSelfHealTool({
    required SelfCorrectingScriptRunner runner,
    this.onReport,
  }) : _runner = runner;

  final SelfCorrectingScriptRunner _runner;

  /// Audit sink opsional (runtime memakai ini untuk AuditLog).
  final void Function(ScriptRunReport report)? onReport;

  @override
  ToolSpec get spec {
    final boundedTimeout =
        (_runner.timeoutSec * _runner.maxAttempts).clamp(1, 60);
    return ToolSpec(
      name: 'script_selfheal',
      description:
          'Jalankan script sekali lalu perbaiki otomatis saat gagal: error '
          '(stderr) dikirim ke advisor untuk patch script lengkap, maksimal '
          '${_runner.maxAttempts} percobaan. Eksperimental; butuh OS sandbox '
          'dan advisor. Audit trail setiap percobaan disertakan di output.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'source': {
            'type': 'string',
            'description': 'Kode script lengkap (maks '
                '${_runner.maxScriptChars} karakter)',
          },
          'entry_file': {
            'type': 'string',
            'description': 'Nama file entry (default run.py)',
          },
          'command': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Perintah eksekusi (default ["python3", entry_file])',
          },
          'args': {
            'type': 'object',
            'description': 'Payload JSON dikirim ke stdin script',
          },
        },
        'required': ['source'],
      },
      risk: 'high',
      timeoutSec: boundedTimeout,
      maxOutputChars: 20000,
    );
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final source = (args['source'] as String?) ?? '';
    if (source.trim().isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'script_selfheal butuh source (kode script lengkap)',
        isError: true,
      );
    }
    final entryFile =
        (args['entry_file'] as String?)?.trim() ?? 'run.py';
    final command = args['command'] is List
        ? (args['command'] as List)
            .map((e) => e.toString())
            .toList(growable: false)
        : null;
    final scriptArgs =
        args['args'] is Map<String, dynamic>
            ? args['args'] as Map<String, dynamic>
            : <String, dynamic>{};

    final ScriptRunReport report;
    try {
      report = await _runner.run(
        source: source,
        entryFile: entryFile,
        command: command,
        args: scriptArgs.isEmpty ? null : scriptArgs,
      );
    } on ArgumentError catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    } on StateError catch (e) {
      return ToolResult(callId: '', content: '$e', isError: true);
    }
    onReport?.call(report);

    final audit = [
      for (final a in report.attempts)
        '- percobaan ${a.attempt} ${a.action}'
            '${a.exitCode != null ? ' (exit ${a.exitCode})' : ''}'
            '${a.errorExcerpt.isEmpty ? '' : ': ${a.errorExcerpt.replaceAll('\n', ' ')}'}',
    ].join('\n');

    if (report.success) {
      return ToolResult(
        callId: '',
        content: '${report.output}\n\n[audit]\n$audit',
      );
    }
    return ToolResult(
      callId: '',
      content:
          'Script gagal setelah loop koreksi (maks '
          '${_runner.maxAttempts} percobaan).\nstderr: ${report.error}\n\n'
          '[audit]\n$audit',
      isError: true,
    );
  }
}
