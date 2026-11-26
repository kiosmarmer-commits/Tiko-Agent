import 'dart:convert';
import 'dart:io';

/// Checkpoint SDD (Hermes `agent/checkpoints/manager.py`): snapshot
/// transparan direktori kerja sebelum operasi yang memutasi file
/// (write_file/patch/shell destruktif) sehingga turn bisa di-rollback.
///
/// Implementasi Dart pakai file-store sederhana (bukan shadow-git): tiap
/// checkpoint adalah direktori `files/` berisi salinan file yang berubah
/// sejak snapshot sebelumnya (dihitung per byte), plus `meta.json`
/// (alasan, waktu, daftar file). Exclude dependency/build/VCS/media.
/// Retensi: simpan [maxCheckpoints] snapshot terbaru.
class SddCheckpoint {
  SddCheckpoint({
    required this.storePath,
    this.maxCheckpoints = 20,
    this.maxFileBytes = 1 * 1024 * 1024,
  });

  final String storePath;
  final int maxCheckpoints;

  /// File di atas batas ini tidak di-snapshot (binary besar/media).
  final int maxFileBytes;

  static const defaultExcludes = [
    'node_modules/',
    'build/',
    'dist/',
    'target/',
    'out/',
    '.dart_tool/',
    '.next/',
    '__pycache__/',
    '.git/',
    '.hg/',
    '.svn/',
    '.venv/',
    'venv/',
    '.worktrees/',
    '.pytest_cache/',
    '.mypy_cache/',
    '.ruff_cache/',
    'coverage/',
  ];

  static const _binaryExt = [
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.mp4', '.mov', '.mkv',
    '.webm', '.zip', '.tar', '.gz', '.7z', '.rar', '.pdf', '.exe', '.dll',
    '.so', '.dylib', '.o', '.a', '.jar', '.class', '.bin', '.ico', '.woff',
    '.woff2', '.ttf', '.eot', '.mp3', '.wav', '.flac', '.sqlite', '.db',
  ];

  final List<SnapshotMeta> _cache = [];
  bool _loaded = false;

  List<SnapshotMeta> get snapshots => List.unmodifiable(_cache);

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final dir = Directory(storePath);
    if (!await dir.exists()) return;
    final ids = <String>[];
    await for (final e in dir.list()) {
      if (e is Directory) {
        final meta = File('${e.path}/meta.json');
        if (await meta.exists()) ids.add(e.path.split('/').last);
      }
    }
    ids.sort();
    _cache.clear();
    for (final id in ids) {
      try {
        final meta = jsonDecode(
          await File('$storePath/$id/meta.json').readAsString(),
        ) as Map<dynamic, dynamic>;
        _cache.add(SnapshotMeta(
          id: id,
          reason: meta['reason']?.toString() ?? '',
          takenAt: DateTime.tryParse(meta['taken_at']?.toString() ?? '') ??
              DateTime.now().toUtc(),
          files: [
            for (final f in (meta['files'] as List? ?? const []))
              f.toString(),
          ],
        ));
      } on Exception {
        // meta korup dilompati.
      }
    }
  }

  /// Snapshot workspace: salin file yang berbeda dari snapshot terakhir.
  /// Return id checkpoint (kosong bila tidak ada perubahan).
  Future<String> create(String workspacePath, {String reason = ''}) async {
    await _ensureLoaded();
    final previousFiles = <String, List<int>>{};
    if (_cache.isNotEmpty) {
      final last = _cache.last;
      for (final rel in last.files) {
        try {
          previousFiles[rel] =
              await File('$storePath/${last.id}/files/$rel').readAsBytes();
        } on Exception {
          // file snapshot hilang — dianggap berubah.
        }
      }
    }

    final root = Directory(workspacePath);
    if (!await root.exists()) return '';
    final id = 'ckpt-${DateTime.now().millisecondsSinceEpoch}';
    final filesDir = '$storePath/$id/files';
    final changed = <String>[];

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(workspacePath.length);
      final norm = rel.startsWith('/') ? rel.substring(1) : rel;
      if (_excluded(norm)) continue;
      try {
        final stat = await entity.stat();
        if (stat.size > maxFileBytes) continue;
        final bytes = await entity.readAsBytes();
        final prev = previousFiles[norm];
        if (prev != null && _sameBytes(prev, bytes)) continue;
        final target = File('$filesDir/$norm');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        changed.add(norm);
      } on FileSystemException {
        continue;
      }
    }

    if (changed.isEmpty) return '';

    final meta = SnapshotMeta(
      id: id,
      reason: reason,
      takenAt: DateTime.now().toUtc(),
      files: changed,
    );
    await File('$storePath/$id/meta.json').writeAsString(
      jsonEncode({
        'reason': meta.reason,
        'taken_at': meta.takenAt.toUtc().toIso8601String(),
        'files': meta.files,
      }),
      flush: true,
    );
    _cache.add(meta);
    await prune();
    return id;
  }

  /// Pulihkan file dari checkpoint [id] ke workspace. File yang ada di
  /// snapshot ditimpa; file yang TIDAK ada di snapshot tidak dihapus
  /// (restore aman, bukan hard reset). Return jumlah file dipulihkan.
  Future<int> restore(String id, String workspacePath) async {
    await _ensureLoaded();
    final meta = _cache.where((m) => m.id == id).firstOrNull;
    if (meta == null) return 0;
    var n = 0;
    for (final rel in meta.files) {
      try {
        final src = File('$storePath/$id/files/$rel');
        if (!await src.exists()) continue;
        final target = File('$workspacePath/$rel');
        await target.parent.create(recursive: true);
        await src.copy(target.path);
        n++;
      } on FileSystemException {
        continue;
      }
    }
    return n;
  }

  /// Hapus snapshot di luar [maxCheckpoints] terbaru.
  Future<int> prune() async {
    await _ensureLoaded();
    var removed = 0;
    while (_cache.length > maxCheckpoints) {
      final oldest = _cache.removeAt(0);
      try {
        await Directory('$storePath/${oldest.id}').delete(recursive: true);
        removed++;
      } on FileSystemException {
        continue;
      }
    }
    return removed;
  }

  bool _excluded(String rel) {
    for (final ex in defaultExcludes) {
      if (ex.endsWith('/')) {
        if (rel.startsWith(ex) || rel.contains('/$ex')) return true;
      } else if (rel == ex) {
        return true;
      }
    }
    for (final ext in _binaryExt) {
      if (rel.toLowerCase().endsWith(ext)) return true;
    }
    return false;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Metadata satu snapshot — publik agar host bisa menampilkan daftar
/// checkpoint (id, alasan, waktu, daftar file).
class SnapshotMeta {
  SnapshotMeta({
    required this.id,
    required this.reason,
    required this.takenAt,
    required this.files,
  });

  final String id;
  final String reason;
  final DateTime takenAt;
  final List<String> files;
}
