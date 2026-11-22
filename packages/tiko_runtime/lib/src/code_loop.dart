part of 'tiko_runtime.dart';

/// Fase B — loop coding/debugging otomatis (paritas Claude Code / Codex):
/// tugas → turn agent (edit file via tool) → verifikasi objektif (perintah
/// nyata) → bila gagal, umpan balik output ke model untuk turn perbaikan
/// berikutnya — terbatas [maxIterations], bukan loop tanpa dasar.
///
/// Prinsip:
/// - **Gate objektif:**.keberhasilan hanya dinyatakan dari exit code 0
///   perintah verifikasi — bukan klaim "sudah selesai" dari model.
/// - **Bounded:** maksimum [maxIterations] turn (default 3) + budget token/
///   waktu tetap ditangani BudgetGuard di dalam tiap turn.
/// - **Checkpoint:** snapshot workspace (.tiko/checkpoints) dibuat sebelum
///   turn pertama; jalur pulih manual via existing `rollback_checkpoint`.
/// - **Fail-closed:** runtime alias verifikasi error dianggap iterasi gagal
///   dengan output jujur, bukan exception yang mematikan proses.
class VerifyRun {
  const VerifyRun({
    required this.iteration,
    required this.ok,
    required this.exitCode,
    required this.output,
  });

  final int iteration;
  final bool ok;
  final int exitCode;
  final String output;
}

class CodeLoopResult {
  const CodeLoopResult({
    required this.success,
    required this.iterations,
    required this.verifyRuns,
    this.checkpointId,
    required this.summary,
    this.tokensUsed = 0,
    this.toolCallCount = 0,
  });

  final bool success;
  final int iterations;
  final List<VerifyRun> verifyRuns;
  final String? checkpointId;
  final String summary;
  final int tokensUsed;
  final int toolCallCount;

  Map<String, dynamic> toJson() => {
        'success': success,
        'iterations': iterations,
        'checkpoint_id': checkpointId,
        'tokens_used': tokensUsed,
        'tool_call_count': toolCallCount,
        'verify_runs': [
          for (final v in verifyRuns)
            {
              'iteration': v.iteration,
              'ok': v.ok,
              'exit_code': v.exitCode,
            },
        ],
        'summary': summary,
      };
}

class CodeLoopRunner {
  CodeLoopRunner({
    required this.runTurn,
    required this.workspacePath,
    required this.checkpointer,
    this.maxOutputChars = 6000,
  });

  /// Satu turn agent penuh (mis. closure ke `TikoRuntime.chatWithStatus`
  /// dengan session/channel khusus loop). Fungsi ini adalah seluruh
  /// integrasi runtime — [CodeLoopRunner] tidak mengenal detail router.
  final Future<ChatRunResult> Function(String prompt) runTurn;

  /// Root workspace tempat checkpoint diambil dan verifikasi dijalankan.
  final String workspacePath;
  final WorkspaceCheckpointer checkpointer;

  /// Berapa banyak karakter output verifikasi yang di-umpan-balik-kan ke
  /// model (tail; error biasanya ada di bagian akhir).
  final int maxOutputChars;

  String _initialPrompt(String task, String verifyCommand) => '''
Tugas coding/debugging: $task

Cara kerja: setor perubahan di workspace SEKARANG dengan tool edit yang
tersedia (write_file / patch_file). Setelah jawabanmu, sistem menjalankan
verifikasi objektif secara otomatis:
  $verifyCommand
Bila verifikasi gagal, kamu akan menerima error-nya sebagai umpan balik.
Perbaiki akar penyebabnya, jangan cuma sembunyikan gejala. Jangan menanya
balik — kerjakan sampai lulus verifikasi atau diberi tahu berhenti.'''.trim();

  String _fixPrompt(
    String task,
    String verifyCommand,
    int iteration,
    VerifyOutcome outcome,
  ) {
    var tail = outcome.output;
    if (tail.length > maxOutputChars) {
      tail = '${tail.substring(tail.length - maxOutputChars)}\n'
          '\u2026[tail terpotong ke $maxOutputChars karakter terakhir]';
    }
    return '''
Verifikasi iterasi $iteration GAGAL (exit ${outcome.exitCode}); perintah:
  $verifyCommand
Task asli: $task

--- output verifikasi (tail) ---
$tail
--- akhir output ---

Perbaiki akar penyebab error di atas di workspace, bukan gejalanya saja.
Setelah jawabanmu verifikasi dijalankan lagi.'''.trim();
  }

  String _trimTail(String s, int max) =>
      s.length <= max ? s : s.substring(s.length - max);

  /// Jalankan loop. Tidak pernah throw — hasil final selalu terstruktur.
  Future<CodeLoopResult> run({
    required String task,
    required String verifyCommand,
    SandboxRunner? sandbox,
    int maxIterations = 3,
    Duration verifyTimeout = const Duration(seconds: 180),
    bool unsandboxedFallback = true,
  }) async {
    final clampedMax = maxIterations.clamp(1, 8);
    final taskTrim = task.trim();
    final verifyTrim = verifyCommand.trim();

    // Checkpoint sebelum edit pertama — jalur pulih dari hasil tiap loop.
    final checkpointId = await checkpointer.createCheckpoint(
      label: 'code-loop sebelum: ${_trimTail(taskTrim, 60)}',
    );

    final verifyRuns = <VerifyRun>[];
    var tokens = 0;
    var toolCalls = 0;
    String lastSummary = '';
    var lastTurn = const ChatRunResult(text: '', success: false);
    var lastOutcome = const VerifyOutcome(
      ok: false,
      exitCode: -1,
      output: '(belum ada verifikasi)',
    );

    for (var i = 1; i <= clampedMax; i++) {
      final prompt = i == 1
          ? _initialPrompt(taskTrim, verifyTrim)
          : _fixPrompt(taskTrim, verifyTrim, verifyRuns.last.iteration,
              lastOutcome);
      try {
        lastTurn = await runTurn(prompt);
      } catch (e) {
        return CodeLoopResult(
          success: false,
          iterations: i - 1,
          verifyRuns: verifyRuns,
          checkpointId: checkpointId,
          tokensUsed: tokens,
          toolCallCount: toolCalls,
          summary: 'Turn agent gagal di iterasi $i: $e — '
              'verifikasi belum selesai; pulihkan workspace bila perlu '
              'dari checkpoint ${checkpointId ?? '(tidak tersedia)'}.',
        );
      }
      tokens += lastTurn.tokensUsed;
      toolCalls += lastTurn.toolCallCount;

      final outcome = await runVerification(
        verifyTrim,
        workspacePath: workspacePath,
        sandbox: sandbox,
        unsandboxedFallback: unsandboxedFallback,
        timeout: verifyTimeout,
      );
      lastOutcome = outcome;
      verifyRuns.add(VerifyRun(
        iteration: i,
        ok: outcome.ok,
        exitCode: outcome.exitCode,
        output: outcome.output,
      ));
      if (outcome.ok) {
        return CodeLoopResult(
          success: true,
          iterations: i,
          verifyRuns: verifyRuns,
          checkpointId: checkpointId,
          tokensUsed: tokens,
          toolCallCount: toolCalls,
          summary: 'Selesai: verifikasi lulus pada iterasi $i dari '
              '$clampedMax (exit 0).',
        );
      }
      lastSummary =
          'verifikasi masih gagal di iterasi $i (exit ${outcome.exitCode})';
    }

    final cpNote = checkpointId == null
        ? 'checkpoint tidak tersedia; perubahan dibiarkan apa adanya agar '
            'bisa diinspeksi'
        : 'pulihkan workspace bila perlu: rollback ke checkpoint '
            '$checkpointId (tool rollback_checkpoint / CLI conversation)';
    return CodeLoopResult(
      success: false,
      iterations: clampedMax,
      verifyRuns: verifyRuns,
      checkpointId: checkpointId,
      tokensUsed: tokens,
      toolCallCount: toolCalls,
      summary: '$lastSummary setelah $clampedMax iterasi. $cpNote. '
          'Jawaban agent terakhir diteruskan apa adanya untuk inspeksi.',
    );
  }
}

/// Fase B — integrasi loop ke [TikoRuntime]: satu panggilan API untuk
/// "perbaiki tugas X sampai verifikasi Y lulus". Session/channel khusus
/// `fix:` supaya log/turn loop terpisah rapi dari chat biasa, dan tool
/// agent difilter ke set coding yang relevan (default bisa dioverride).
extension CodeLoopWiring on TikoRuntime {
  /// Default tool yang boleh dipakai turn dalam loop fix: baca/tulis file,
  /// patch, grep, verifikasi, unzip. Tidak ada network/script di default —
  /// bisa diperluas lewat [extraTools].
  static const Set<String> defaultFixTools = {
    'read_file', 'list_dir', 'grep', 'write_file', 'patch_file',
    'verify_project', 'unzip_archive', 'datetime',
  };

  Future<CodeLoopResult> runCodeFixLoop({
    required String task,
    required String verifyCommand,
    String sessionKey = 'default',
    int maxIterations = 3,
    Duration verifyTimeout = const Duration(seconds: 180),
    int? maxToolCalls,
    bool unsandboxedVerification = true,
    Set<String>? extraTools,
    void Function(String toolName)? onToolStart,
    void Function(ToolCallTrace trace)? onToolTrace,
  }) async {
    final tools = {
      ...defaultFixTools,
      if (extraTools != null) ...extraTools,
    };
    final sessionId = 'fix:$sessionKey';
    final runner = CodeLoopRunner(
      runTurn: (prompt) {
        events.emit('code_loop.turn_started', {
          'session_id': sessionId,
          'command': verifyCommand,
        });
        return chatWithStatus(
          prompt,
          sessionId: sessionId,
          channel: 'fix',
          userKey: 'fix',
          toolFilter: tools,
          configOverride: maxToolCalls == null
              ? null
              : AgentConfig(maxToolCalls: maxToolCalls),
          onToolStart: onToolStart,
          onToolTrace: onToolTrace,
        );
      },
      workspacePath: workspace,
      checkpointer: WorkspaceCheckpointer(workspaceRoot: workspace),
    );
    final result = await runner.run(
      task: task,
      verifyCommand: verifyCommand,
      sandbox: SandboxRunner(
        kind: sandboxKind,
        workspacePath: workspace,
      ),
      maxIterations: maxIterations,
      verifyTimeout: verifyTimeout,
      unsandboxedFallback: unsandboxedVerification,
    );
    events.emit('code_loop.finished', result.toJson());
    return result;
  }
}
