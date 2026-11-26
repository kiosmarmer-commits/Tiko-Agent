import 'package:agent_core/agent_core.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Registry proses background (Hermes `terminal(background=true)`): proses
/// jangka panjang diluncurkan tanpa memblokir turn, outputnya ditampung
/// rolling buffer (~200KB), lalu dipantau lewat aksi poll/log/wait/kill.
///
/// Checkpoint JSON durabel menyimpan daftar proses + buffer sehingga setelah
/// crash/restart registry dapat memulihkan status: proses yang pid-nya tidak
/// ada lagi ditandai `exited (unknown)`, yang masih hidup tetap bisa
/// dipantau. Env proses di-scope eksplisit (includeParentEnvironment=false)
/// agar tidak membocorkan environment penuh host ke proses anak.
class BackgroundProcess {
  BackgroundProcess({
    required this.id,
    required this.command,
    required this.pid,
    required this.startedAt,
    this.exitCode,
    this.exitNote,
  });

  final String id;
  final String command;
  final int pid;
  final DateTime startedAt;

  /// null = masih berjalan.
  int? exitCode;

  /// Catatan keluar khusus, mis. 'killed' atau 'recovered (pid tidak ada)'.
  String? exitNote;

  Process? _process;
  final StringBuffer _buffer = StringBuffer();
  int _polledCursor = 0;
  bool _bufferDirty = false;

  bool get isRunning => exitCode == null && exitNote == null;

  /// Status ringkas satu baris untuk poll.
  String get status {
    if (exitNote != null) return 'exited: $exitNote';
    if (exitCode != null) return 'exited: code $exitCode';
    return 'running';
  }

  /// Output baru sejak poll terakhir + status. Tidak mengulang output lama.
  String poll() {
    final text = _buffer.toString();
    final fresh = text.length > _polledCursor
        ? text.substring(_polledCursor)
        : '';
    _polledCursor = text.length;
    final buf = StringBuffer('status: $status\n');
    if (fresh.isNotEmpty) buf.write(fresh);
    if (!fresh.endsWith('\n') && fresh.isNotEmpty) buf.writeln();
    return buf.toString();
  }

  /// Seluruh output yang tertampung (dibatasi kapasitas rolling buffer).
  String log() => 'status: $status\n${_buffer.toString()}';

  /// Tunggu proses selesai (maks [timeout]); return status terakhir.
  Future<String> wait({Duration timeout = const Duration(seconds: 30)}) async {
    final proc = _process;
    if (proc != null && isRunning) {
      try {
        exitCode = await proc.exitCode.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('wait timeout'),
        );
      } on TimeoutException {
        return 'still running (timeout ${timeout.inSeconds}s)';
      }
    }
    return status;
  }

  Future<void> kill({ProcessSignal signal = ProcessSignal.sigterm}) async {
    if (!isRunning) return;
    exitNote = 'killed';
    try {
      final proc = _process;
      if (proc != null) {
        proc.kill(signal);
      } else {
        Process.killPid(pid, signal);
      }
    } on Exception {
      // Proses mungkin sudah mati sendiri.
    }
  }

  void _append(String chunk) {
    _buffer.write(chunk);
    _bufferDirty = true;
    if (_buffer.length > maxBufferChars) {
      final text = _buffer.toString();
      final trimmed =
          text.substring(text.length - maxBufferChars);
      final nl = trimmed.indexOf('\n');
      _buffer
        ..clear()
        ..write(nl < 0 ? trimmed : trimmed.substring(nl + 1));
      if (_polledCursor > _buffer.length) _polledCursor = 0;
    }
  }

  /// Kapasitas rolling buffer (char) — Hermes pakai ~200KB.
  static const maxBufferChars = 200000;

  Map<String, dynamic> toCheckpointJson() => {
        'id': id,
        'command': command,
        'pid': pid,
        'started_at': startedAt.toUtc().toIso8601String(),
        'exit_code': exitCode,
        'exit_note': exitNote,
        'buffer': _buffer.toString(),
        'polled_cursor': _polledCursor,
      };

  static BackgroundProcess fromCheckpointJson(Map<dynamic, dynamic> j) {
    final bp = BackgroundProcess(
      id: j['id']?.toString() ?? '',
      command: j['command']?.toString() ?? '',
      pid: (j['pid'] as num?)?.toInt() ?? 0,
      startedAt: DateTime.tryParse(j['started_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      exitCode: (j['exit_code'] as num?)?.toInt(),
      exitNote: j['exit_note']?.toString(),
    );
    bp._buffer.write(j['buffer']?.toString() ?? '');
    bp._polledCursor = (j['polled_cursor'] as num?)?.toInt() ?? 0;
    return bp;
  }

  bool get bufferDirty => _bufferDirty;
  void clearBufferDirty() => _bufferDirty = false;
}

class ProcessRegistry {
  ProcessRegistry({
    required this.checkpointPath,
    this.defaultWorkingDirectory,
    this.defaultEnv = const {},
  });

  final String checkpointPath;
  final String? defaultWorkingDirectory;

  /// Env tambahan yang selalu di-scope ke proses anak. Environment penuh
  /// host TIDAK diwariskan (includeParentEnvironment=false) kecuali
  /// [inheritParentEnv] diaktifkan per-start.
  final Map<String, String> defaultEnv;
  bool inheritParentEnv = false;

  final Map<String, BackgroundProcess> _processes = {};
  int _counter = 0;

  Iterable<BackgroundProcess> get all => _processes.values;
  BackgroundProcess? get(String id) => _processes[id];

  /// Luncurkan proses background. Return handle untuk poll/log/wait/kill.
  Future<BackgroundProcess> start(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? env,
  }) async {
    _counter++;
    final id = 'bg-$_counter-${DateTime.now().millisecondsSinceEpoch}';
    final proc = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory ?? defaultWorkingDirectory,
      environment: {...defaultEnv, ...?env},
      includeParentEnvironment: inheritParentEnv,
      mode: ProcessStartMode.normal,
    );
    final bp = BackgroundProcess(
      id: id,
      command: command.join(' '),
      pid: proc.pid,
      startedAt: DateTime.now().toUtc(),
    ).._process = proc;
    _processes[id] = bp;
    proc.stdout.transform(utf8.decoder).listen(bp._append);
    proc.stderr.transform(utf8.decoder).listen((s) => bp._append('[stderr] $s'));
    unawaited(proc.exitCode.then((code) {
      bp.exitCode = code;
      bp._append('\n[exited: code $code]\n');
    }));
    await checkpoint();
    return bp;
  }

  /// Muat checkpoint dan pulihkan status: pid tidak hidup lagi → exited
  /// unknown; masih hidup → tetap terdaftar (output baru tidak tersedia,
  /// tapi buffer lama utuh dan kill masih bisa dikirim).
  Future<int> recover() async {
    final f = File(checkpointPath);
    if (!await f.exists()) return 0;
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return 0;
      final list = decoded['processes'];
      if (list is! List) return 0;
      var n = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final bp = BackgroundProcess.fromCheckpointJson(raw);
        if (bp.id.isEmpty || _processes.containsKey(bp.id)) continue;
        if (bp.isRunning && !pidAlive(bp.pid)) {
          bp.exitNote = 'recovered: pid ${bp.pid} tidak ada lagi';
        }
        _processes[bp.id] = bp;
        n++;
      }
      return n;
    } on Exception {
      return 0;
    }
  }

  /// Simpan checkpoint semua proses (id, command, pid, buffer, status).
  Future<void> checkpoint() async {
    try {
      final file = File(checkpointPath);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'processes': [
            for (final bp in _processes.values) bp.toCheckpointJson(),
          ],
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException {
      // best-effort
    }
  }

  /// Liveness pid Linux via /proc; platform lain → diasumsikan tidak hidup
  /// (fail-closed untuk recovery: proses ditandai exited, bukan zombie).
  static bool pidAlive(int pid) {
    if (pid <= 0) return false;
    try {
      return Directory('/proc/$pid').existsSync();
    } on Exception {
      return false;
    }
  }
}

/// Tool wrapper registry proses background — padanan Hermes
/// `terminal(background=true)`. Satu tool, lima aksi: `start`, `poll`,
/// `log`, `wait`, `kill`. Risk high: start/kill selalu lewat gate izin.
class BackgroundProcessTool implements Tool {
  BackgroundProcessTool({required this.registry, this.maxOutputChars = 20000});

  final ProcessRegistry registry;
  final int maxOutputChars;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'process_bg',
    description:
        'Kelola proses background: start/poll/log/wait/kill. Output rolling '
        'buffer, bertahan lintas turn, dipulihkan setelah crash.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['start', 'poll', 'log', 'wait', 'kill'],
        },
        'id': {
          'type': 'string',
          'description': 'ID proses (wajib untuk poll/log/wait/kill).',
        },
        'command': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'argv tanpa interpreter shell, mis. ["flutter", "test"]. '
              'Wajib untuk action=start.',
        },
        'timeout_sec': {'type': 'number'},
      },
      'required': ['action'],
    },
    risk: 'high',
    timeoutSec: 45,
    maxOutputChars: 50000,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['action'] as String?)?.trim() ?? '';
    final id = (args['id'] as String?)?.trim();
    switch (action) {
      case 'start':
        final raw = args['command'];
        final command = raw is List
            ? raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
            : <String>[];
        if (command.isEmpty) {
          return const ToolResult(
            callId: '',
            content: 'action=start butuh command (argv array).',
            isError: true,
          );
        }
        try {
          final bp = await registry.start(
            command,
            workingDirectory: ctx.workspacePath,
          );
          return ToolResult(
            callId: '',
            content: 'started ${bp.id} (pid ${bp.pid}): ${bp.command}\n'
                'Pantau dengan action=poll id=${bp.id}.',
          );
        } catch (e) {
          return ToolResult(
            callId: '',
            content: 'gagal start: $e',
            isError: true,
          );
        }
      case 'poll':
      case 'log':
      case 'wait':
      case 'kill':
        if (id == null || id.isEmpty) {
          return ToolResult(
            callId: '',
            content: 'action=$action butuh id proses.',
            isError: true,
          );
        }
        final bp = registry.get(id);
        if (bp == null) {
          return ToolResult(
            callId: '',
            content: 'proses tidak ditemukan: $id',
            isError: true,
          );
        }
        switch (action) {
          case 'poll':
            return ToolResult(callId: '', content: _cap(bp.poll()));
          case 'log':
            return ToolResult(callId: '', content: _cap(bp.log()));
          case 'wait':
            final timeoutSec = (args['timeout_sec'] as num?)?.toInt() ?? 30;
            final status = await bp.wait(
              timeout: Duration(seconds: timeoutSec.clamp(1, 120)),
            );
            return ToolResult(callId: '', content: _cap('$status\n${bp.log()}'));
          case 'kill':
            await bp.kill();
            await registry.checkpoint();
            return ToolResult(callId: '', content: 'killed ${bp.id}');
          default:
            return ToolResult(
              callId: '',
              content: 'aksi tidak didukung: $action',
              isError: true,
            );
        }
      default:
        return ToolResult(
          callId: '',
          content:
              'action tidak dikenal: $action (start/poll/log/wait/kill).',
          isError: true,
        );
    }
  }

  String _cap(String text) {
    if (text.length <= maxOutputChars) return text;
    return '${text.substring(text.length - maxOutputChars)}\n…[truncated]';
  }
}
