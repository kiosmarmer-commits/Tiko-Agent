// Hermes parity: `agent/checkpoints/` (manager.py, refs.py, undo_hint.py,
// pruning.py) — snapshot file workspace SEBELUM mutasi sehingga `/undo`
// bisa memulihkan keadaan pra-turn.
//
// Deviasi sadar dari Hermes (didokumentasikan): Hermes memakai shadow git
// store bersama lintas proses dengan retention penuh; Tiko memakai
// snapshot in-memory per sesi yang terikat batas ketat (per-file ≤
// `maxFileBytes`, per-batch ≤ `maxBatchFiles`, riwayat per sesi dibatasi
// host) — cukup untuk undo tingkat turn, tanpa menyimpan duplikat konten
// di luar umur proses.
//
// Fail-closed: path di luar jail workspace (absolut, `..`, escape root)
// tidak pernah di-snapshot; semua operasi never-raises.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Satu snapshot isi file SEBELUM mutasi (satu tool call mutatif).
class FileCheckpoint {
  const FileCheckpoint({
    required this.id,
    required this.relPath,
    required this.existed,
    this.content,
    required this.at,
    required this.reason,
  });

  /// Id unik checkpoint (`cp-<epochMs>-<seq>`).
  final String id;

  /// Path relatif workspace (sudah tervalidasi jail).
  final String relPath;

  /// False = file belum ada saat snapshot → restore menghapus file.
  final bool existed;

  /// Isi pre-mutasi (null bila [existed] false).
  final String? content;
  final DateTime at;

  /// Nama tool yang memicu snapshot (write_file / patch_file).
  final String reason;

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': relPath,
        'existed': existed,
        if (content != null) 'content_base64': base64.encode(utf8.encode(content!)),
        'at': at.toIso8601String(),
        'reason': reason,
      };

  static FileCheckpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final path = raw['path'];
    final reason = raw['reason'];
    final at = raw['at'];
    if (id is! String || path is! String || reason is! String) return null;
    final parsedAt = DateTime.tryParse(at is String ? at : '');
    if (parsedAt == null) return null;
    final existed = raw['existed'] == true;
    String? content;
    final b64 = raw['content_base64'];
    if (existed && b64 is String) {
      try {
        content = utf8.decode(base64.decode(b64));
      } catch (_) {
        return null;
      }
    }
    return FileCheckpoint(
      id: id,
      relPath: path,
      existed: existed,
      content: existed ? content : null,
      at: parsedAt,
      reason: reason,
    );
  }
}

/// Store snapshot checkpoint + restore.
class CheckpointStore {
  CheckpointStore({
    this.maxFileBytes = 1 << 20,
    this.maxBatchFiles = 10,
  });

  /// File lebih besar dari ini tidak di-snapshot (snapshot bukan backup
  /// penuh workspace — Hermes juga membatasi ukuran).
  final int maxFileBytes;

  /// Maksimum file per batch tool (batch paralel bisa memuat banyak call).
  final int maxBatchFiles;

  int _seq = 0;

  String _nextId() {
    _seq += 1;
    return 'cp-${DateTime.now().microsecondsSinceEpoch}-$_seq';
  }

  /// Validasi jail: relatif, tanpa `..` yang lolos, tetap di dalam root.
  /// Return path absolut yang aman, atau null bila melanggar.
  String? _resolveInside(String workspaceRoot, String relPath) {
    try {
      if (relPath.trim().isEmpty) return null;
      if (p.isAbsolute(relPath)) return null;
      final root = p.normalize(p.absolute(workspaceRoot));
      final resolved = p.normalize(p.join(root, relPath));
      if (resolved == root || !p.isWithin(root, resolved)) return null;
      return resolved;
    } catch (_) {
      return null;
    }
  }

  /// Snapshot SATU file sebelum mutasi. Return null bila path tak valid,
  /// tak terbaca, atau melebihi batas ukuran — snapshot bukan keharusan
  /// eksekusi tool (mutasi tetap berjalan tanpa undo).
  FileCheckpoint? snapshotFile(
    String workspaceRoot,
    String? relPath, {
    required String reason,
  }) {
    try {
      if (relPath == null) return null;
      final resolved = _resolveInside(workspaceRoot, relPath);
      if (resolved == null) return null;
      final f = File(resolved);
      if (!f.existsSync()) {
        return FileCheckpoint(
          id: _nextId(),
          relPath: p.normalize(relPath),
          existed: false,
          content: null,
          at: DateTime.now().toUtc(),
          reason: reason,
        );
      }
      final stat = f.statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      if (stat.size > maxFileBytes) return null;
      final content = f.readAsStringSync();
      return FileCheckpoint(
        id: _nextId(),
        relPath: p.normalize(relPath),
        existed: true,
        content: content,
        at: DateTime.now().toUtc(),
        reason: reason,
      );
    } catch (_) {
      return null;
    }
  }

  /// Snapshot batch tool call mutatif (`{name: path}` dari args). Maks
  /// [maxBatchFiles] file per batch; sisanya diabaikan (fail-open).
  List<FileCheckpoint> snapshotBatch(
    String workspaceRoot,
    Iterable<(String name, String? path)> calls,
  ) {
    final out = <FileCheckpoint>[];
    for (final (name, path) in calls) {
      if (out.length >= maxBatchFiles) break;
      final cp = snapshotFile(workspaceRoot, path, reason: name);
      if (cp != null) out.add(cp);
    }
    return out;
  }

  /// Pulihkan satu batch checkpoint: tulis kembali isi lama, hapus file
  /// yang sebelumnya belum ada. Return (restored, failed) — path yang
  /// berhasil dan yang gagal dipulihkan (never-raises per file).
  (List<String>, List<String>) restore(
    String workspaceRoot,
    List<FileCheckpoint> checkpoints,
  ) {
    final restored = <String>[];
    final failed = <String>[];
    for (final cp in checkpoints) {
      try {
        final resolved = _resolveInside(workspaceRoot, cp.relPath);
        if (resolved == null) {
          failed.add(cp.relPath);
          continue;
        }
        if (!cp.existed) {
          final f = File(resolved);
          if (f.existsSync()) f.deleteSync();
          restored.add(cp.relPath);
          continue;
        }
        final f = File(resolved);
        final parent = f.parent;
        if (!parent.existsSync()) parent.createSync(recursive: true);
        f.writeAsStringSync(cp.content ?? '', flush: true);
        restored.add(cp.relPath);
      } catch (_) {
        failed.add(cp.relPath);
      }
    }
    return (restored, failed);
  }
}

