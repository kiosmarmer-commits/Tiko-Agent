import 'dart:io';

import 'package:agent_core/agent_core.dart';

import 'path_safety.dart';

/// Satu operasi yang tercatat agar bisa dibatalkan.
class UndoEntry {
  UndoEntry({
    required this.description,
    this.path,
    this.before,
    this.existed = false,
  });

  final String description;
  final String? path;
  final String? before;
  final bool existed;
  bool undone = false;
}

/// undo_ledger (NEW-11): ledger operasi yang bisa dibatalkan. Sebelum
/// menulis/menghapus file, agent mencatat snapshot-nya lewat
/// record_undoable; undo membatalkan operasi terakhir (LIFO).
class UndoLedger {
  final List<UndoEntry> _entries = [];

  /// Mencatat operasi baru (dengan snapshot opsional).
  UndoEntry record({
    required String description,
    String? path,
    String? before,
    required bool existed,
  }) {
    final e = UndoEntry(
      description: description,
      path: path,
      before: before,
      existed: existed,
    );
    _entries.add(e);
    return e;
  }

  /// Mengambil dan menghapus entri terakhir (LIFO); null bila kosong.
  UndoEntry? popLast() {
    if (_entries.isEmpty) return null;
    return _entries.removeLast();
  }

  /// Semua entri terurut pencatatan.
  List<UndoEntry> get entries => List.unmodifiable(_entries);

  /// Jumlah entri tersisa.
  int get length => _entries.length;
}

/// record_undoable — catat operasi SEBELUM dieksekusi.
class RecordUndoableTool implements Tool {
  RecordUndoableTool({required this.ledger});

  final UndoLedger ledger;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'record_undoable',
    description:
        'Catat operasi yang bisa dibatalkan SEBELUM dieksekusi: bila '
        'path diberikan, isi file saat ini disimpan otomatis sebagai '
        'snapshot untuk undo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'description': {
          'type': 'string',
          'description': 'Deskripsi operasi (1-200 karakter).',
        },
        'path': {
          'type': 'string',
          'description': 'Path file relatif (opsional).',
        },
      },
      'required': ['description'],
    },
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final description = (args['description'] as String?)?.trim() ?? '';
    if (description.isEmpty || description.length > 200) {
      return const ToolResult(
        callId: '',
        content: 'description wajib 1-200 karakter',
        isError: true,
      );
    }
    final rawPath = (args['path'] as String?)?.trim() ?? '';
    if (rawPath.isEmpty) {
      ledger.record(description: description);
      return const ToolResult(
        callId: '',
        content: 'OK tercatat tanpa file (tidak ada snapshot)',
      );
    }
    final resolved = PathSafety.resolveInRoot(ctx.workspacePath, rawPath);
    if (resolved == null) {
      return const ToolResult(
        callId: '',
        content: 'path di luar workspace',
        isError: true,
      );
    }
    final file = File(resolved);
    if (!file.existsSync()) {
      ledger.record(
        description: description,
        path: resolved,
        existed: false,
      );
      return const ToolResult(
        callId: '',
        content: 'OK tercatat: file belum ada (undo akan menghapusnya)',
      );
    }
    final before = _readFile(file);
    if (before == null) {
      return const ToolResult(
        callId: '',
        content: 'file tidak bisa dibaca sebagai UTF-8',
        isError: true,
      );
    }
    ledger.record(
      description: description,
      path: resolved,
      before: before,
      existed: true,
    );
    return ToolResult(
      callId: '',
      content: 'OK tercatat (snapshot disimpan)',
    );
  }

  String? _readFile(File f) {
    try {
      return f.readAsStringSync();
    } catch (_) {
      return null;
    }
  }
}

/// undo — batalkan operasi terakhir yang tercatat (LIFO).
class UndoTool implements Tool {
  UndoTool({required this.ledger});

  final UndoLedger ledger;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'undo',
    description:
        'Batalkan operasi terakhir yang dicatat record_undoable: isi '
        'file dipulihkan dari snapshot, atau file yang baru dibuat '
        'dihapus.',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'medium',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final e = ledger.popLast();
    if (e == null) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada operasi yang bisa dibatalkan.',
        isError: true,
      );
    }
    final path = e.path;
    if (path == null) {
      e.undone = true;
      return ToolResult(
        callId: '',
        content: 'OK dibatalkan (tanpa file): ${e.description}',
      );
    }
    if (e.existed) {
      final before = e.before;
      if (before == null) {
        return const ToolResult(
          callId: '',
          content: 'snapshot hilang; tidak bisa memulihkan',
          isError: true,
        );
      }
      File(path).writeAsStringSync(before);
    } else {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    e.undone = true;
    return ToolResult(
      callId: '',
      content: 'OK dibatalkan: ${e.description}',
    );
  }
}

/// list_undo — daftar operasi yang masih bisa dibatalkan.
class ListUndoTool implements Tool {
  ListUndoTool({required this.ledger});

  final UndoLedger ledger;

  @override
  ToolSpec get spec => const ToolSpec(
    name: 'list_undo',
    description: 'Daftar operasi yang masih bisa dibatalkan (terbaru '
        'dulu).',
    inputSchema: {'type': 'object', 'properties': {}},
    risk: 'low',
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    final entries = ledger.entries;
    if (entries.isEmpty) {
      return const ToolResult(
        callId: '',
        content: 'Tidak ada operasi yang bisa dibatalkan.',
        isError: true,
      );
    }
    final lines = <String>[];
    for (var i = entries.length - 1; i >= 0; i--) {
      final e = entries[i];
      final path = e.path == null ? '' : ' → ${e.path}';
      lines.add('${entries.length - i}. ${e.description}$path');
    }
    return ToolResult(callId: '', content: lines.join('\n'));
  }
}
