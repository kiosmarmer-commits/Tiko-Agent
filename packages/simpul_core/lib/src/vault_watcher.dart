import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One batch of changed notes: vault-relative POSIX paths, deduped and
/// sorted, ready for an incremental sync (NFR-S05).
class VaultWatchBatch {
  const VaultWatchBatch({required this.paths, required this.at});

  final List<String> paths;
  final DateTime at;
}

/// Watches a vault folder for note changes (FR-01: read-only, never writes)
/// and emits batches of changed `.md` paths for incremental sync.
///
/// Implementation is a polling snapshot diff (mtime+size per note) instead of
/// inotify: recursive `Directory.watch` is unreliable on network/synced
/// filesystems (virtiofs, NFS, cloud-sync folders — a common home for
/// Obsidian vaults) and polling needs no platform channels, so the same code
/// works on desktop, mobile, and Termux.
class VaultWatcher {
  VaultWatcher(this.vaultDir);

  final String vaultDir;

  /// Emits one batch per [interval] containing every note created, modified,
  /// or removed since the previous tick (empty ticks are skipped). The
  /// stream never completes; cancel the subscription to stop watching.
  Stream<VaultWatchBatch> batches({
    Duration interval = const Duration(seconds: 1),
  }) {
    late final StreamController<VaultWatchBatch> controller;
    Timer? timer;
    var busy = false;
    var previous = <String, ({int mtimeNs, int size})>{};

    Future<void> tick() async {
      if (busy || !controller.hasListener) return;
      busy = true;
      try {
        final current = await snapshot();
        final changed = <String>{
          for (final entry in current.entries)
            if (previous[entry.key] != entry.value) entry.key,
          for (final path in previous.keys)
            if (!current.containsKey(path)) path,
        };
        previous = current;
        if (changed.isNotEmpty) {
          controller.add(VaultWatchBatch(
            paths: changed.toList()..sort(),
            at: DateTime.now(),
          ));
        }
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        busy = false;
      }
    }

    controller = StreamController<VaultWatchBatch>(
      onListen: () async {
        previous = await snapshot();
        timer = Timer.periodic(interval, (_) => tick());
      },
      onPause: () => timer?.cancel(),
      onResume: () => timer = Timer.periodic(interval, (_) => tick()),
      onCancel: () {
        timer?.cancel();
        return Future.value();
      },
    );
    return controller.stream;
  }

  Future<Map<String, ({int mtimeNs, int size})>> snapshot() async {
    final result = <String, ({int mtimeNs, int size})>{};
    await for (final entity
        in Directory(vaultDir).list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final relative = relativeNotePath(entity.path);
      if (relative == null) continue;
      final stat = await entity.stat();
      result[relative] = (
        mtimeNs: stat.modified.millisecondsSinceEpoch * 1000000,
        size: stat.size,
      );
    }
    return result;
  }

  /// Vault-relative POSIX path for a tracked note, or null when the path is
  /// not a note (non-Markdown or inside a hidden folder like `.obsidian`,
  /// `.simpul`, `.git`).
  String? relativeNotePath(String path) {
    if (!path.endsWith('.md')) return null;
    final relative = p.relative(path, from: vaultDir);
    final segments = relative.split(RegExp(r'[\\/]'));
    if (segments.any((s) => s.startsWith('.'))) return null;
    return relative.replaceAll('\\', '/');
  }
}
