import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';
import 'sandbox.dart';

/// Command executor used by exit0 checks; injectable for tests.
typedef GuardCommandRunner = Future<ProcessResult> Function(
  List<String> parts,
);

/// One declared invariant: an exit-0 command contract or an untouched
/// path contract.
class InvariantSpec {
  const InvariantSpec({
    required this.id,
    required this.kind,
    required this.target,
  });

  final String id;
  final String kind;
  final String target;
}

/// Result of verifying one invariant.
class InvariantResult {
  const InvariantResult({
    required this.id,
    required this.ok,
    required this.detail,
  });

  final String id;
  final bool ok;
  final String detail;
}

/// Machine-checked task invariants (NEW-03): the agent declares
/// contracts at the start of a task and the harness re-verifies them
/// after every writing step, so regressions surface before the final
/// answer. `exit0` runs a command (sandboxed, fail-closed when no OS
/// sandbox exists); `unchanged` compares mtime+size snapshots of a
/// file or directory taken at declare time.
class InvariantGuard {
  InvariantGuard({
    required this.workspaceRoot,
    this.sandbox,
    GuardCommandRunner? commandRunner,
  }) : _commandRunner = commandRunner;

  final String workspaceRoot;
  final SandboxRunner? sandbox;
  final GuardCommandRunner? _commandRunner;

  final List<InvariantSpec> _specs = [];
  final Map<String, Map<String, _FileStamp>> _snapshots = {};

  /// Replaces every previous declaration and snapshots all
  /// `unchanged` targets.
  void declare(List<InvariantSpec> specs) {
    _specs
      ..clear()
      ..addAll(specs);
    _snapshots.clear();
    for (final spec in specs) {
      if (spec.kind == 'unchanged') {
        _snapshots[spec.id] = _stampSync(spec.target);
      }
    }
  }

  /// Runs every declared invariant and returns per-spec results.
  Future<List<InvariantResult>> verify() async {
    final out = <InvariantResult>[];
    for (final spec in _specs) {
      if (spec.kind == 'exit0') {
        out.add(await _checkExit0(spec));
      } else {
        out.add(_checkUnchanged(spec));
      }
    }
    return out;
  }

  Future<InvariantResult> _checkExit0(InvariantSpec spec) async {
    final parts = spec.target
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return InvariantResult(id: spec.id, ok: false, detail: 'command kosong');
    }
    try {
      final ProcessResult result;
      final runner = _commandRunner;
      if (runner != null) {
        result = await runner(parts);
      } else {
        final sb = sandbox;
        if (sb == null) {
          return InvariantResult(
            id: spec.id,
            ok: false,
            detail: 'sandbox tidak tersedia (fail-closed)',
          );
        }
        result = await sb.run(parts, timeout: const Duration(seconds: 20));
      }
      return InvariantResult(
        id: spec.id,
        ok: result.exitCode == 0,
        detail: 'exit ${result.exitCode}',
      );
    } catch (e) {
      return InvariantResult(id: spec.id, ok: false, detail: 'error: $e');
    }
  }

  InvariantResult _checkUnchanged(InvariantSpec spec) {
    final snap = _snapshots[spec.id] ?? const <String, _FileStamp>{};
    final now = _stampSync(spec.target);
    var changed = 0;
    for (final e in now.entries) {
      final s = snap[e.key];
      if (s == null || s != e.value) changed++;
    }
    for (final k in snap.keys) {
      if (!now.containsKey(k)) changed++;
    }
    return InvariantResult(
      id: spec.id,
      ok: changed == 0,
      detail: changed == 0
          ? '${spec.target} utuh (${snap.length} file)'
          : '$changed file berubah sejak snapshot',
    );
  }

  Map<String, _FileStamp> _stampSync(String target) {
    final resolved = PathSafety.resolveInRoot(workspaceRoot, target);
    final out = <String, _FileStamp>{};
    if (resolved == null) return out;
    final type = FileSystemEntity.typeSync(resolved, followLinks: true);
    if (type == FileSystemEntityType.file) {
      final st = File(resolved).statSync();
      out[resolved] =
          _FileStamp(st.modified.millisecondsSinceEpoch, st.size);
    } else if (type == FileSystemEntityType.directory) {
      final entries = Directory(resolved)
          .listSync(recursive: true, followLinks: false);
      for (final e in entries) {
        if (e is! File) continue;
        final st = e.statSync();
        out[e.path] =
            _FileStamp(st.modified.millisecondsSinceEpoch, st.size);
      }
    }
    return out;
  }
}

class _FileStamp {
  const _FileStamp(this.mtimeMs, this.size);

  final int mtimeMs;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is _FileStamp &&
      other.mtimeMs == mtimeMs &&
      other.size == size;

  @override
  int get hashCode => Object.hash(mtimeMs, size);
}

/// invariant_declare — declare the task's machine-checked contracts.
class InvariantDeclareTool implements Tool {
  InvariantDeclareTool({required this.guard});

  final InvariantGuard guard;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'invariant_declare',
    description:
        'Deklarasikan invarian tugas (mengganti deklarasi lama): kind '
        'exit0 (target perintah, wajib exit 0) atau unchanged (target '
        'path file/direktori yang tidak boleh berubah).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'invariants': {
          'type': 'array',
          'description': 'Array {id, kind: exit0|unchanged, target}.',
        },
      },
      'required': ['invariants'],
    },
    risk: 'high',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final raw = args['invariants'];
    if (raw is! List || raw.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'invariants wajib array tidak kosong',
        isError: true,
      );
    }
    if (raw.length > 20) {
      return const ToolResult(
        callId: '',
        content: 'maksimal 20 invarian',
        isError: true,
      );
    }
    final specs = <InvariantSpec>[];
    for (final item in raw) {
      if (item is! Map) {
        return const ToolResult(
          callId: '',
          content: 'setiap invarian harus objek {id, kind, target}',
          isError: true,
        );
      }
      final id = item['id']?.toString() ?? '';
      final kind = item['kind']?.toString() ?? '';
      final target = item['target']?.toString() ?? '';
      if (id.isEmpty || target.isEmpty) {
        return const ToolResult(
          callId: '',
          content: 'id dan target wajib diisi',
          isError: true,
        );
      }
      if (kind != 'exit0' && kind != 'unchanged') {
        return const ToolResult(
          callId: '',
          content: 'kind harus exit0 atau unchanged',
          isError: true,
        );
      }
      specs.add(InvariantSpec(id: id, kind: kind, target: target));
    }
    guard.declare(specs);
    return ToolResult(
      callId: '',
      content: 'OK ${specs.length} invarian dideklarasikan',
    );
  }
}

/// invariant_check — re-verify every declared invariant.
class InvariantCheckTool implements Tool {
  InvariantCheckTool({required this.guard});

  final InvariantGuard guard;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'invariant_check',
    description:
        'Jalankan semua invarian yang dideklarasikan dan laporkan '
        'statusnya. Panggil setelah setiap langkah yang menulis.',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'high',
    timeoutSec: 30,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final results = await guard.verify();
    if (results.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Belum ada invarian yang dideklarasikan',
        isError: true,
      );
    }
    final lines = <String>[];
    var allOk = true;
    for (final r in results) {
      if (!r.ok) allOk = false;
      lines.add('${r.ok ? 'OK  ' : 'FAIL'} ${r.id}: ${r.detail}');
    }
    return ToolResult(
      callId: '',
      content: lines.join('\n'),
      isError: !allOk,
    );
  }
}
