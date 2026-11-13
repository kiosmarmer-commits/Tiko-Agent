import 'vault_index.dart';
import 'vault_scanner.dart';

class SyncResult {
  const SyncResult({
    required this.added,
    required this.updated,
    required this.removed,
    required this.unchanged,
  });

  final List<String> added;
  final List<String> updated;
  final List<String> removed;
  final int unchanged;

  Map<String, Object?> toJson() => {
        'added': added.length,
        'updated': updated.length,
        'removed': removed.length,
        'unchanged': unchanged,
      };
}

/// Incremental vault sync (NFR-S05, NFR-08): compares the vault against the
/// index's cached scan state and applies only the changed subset.
abstract final class VaultSync {
  static Future<SyncResult> apply(VaultIndex index, String vaultDir) async {
    final previous = await index.stats();
    final diff = await VaultScanner.diff(vaultDir, previous);

    final added = [
      for (final note in diff.changed)
        if (!previous.containsKey(note.path)) note.path,
    ];
    final updated = [
      for (final note in diff.changed)
        if (previous.containsKey(note.path)) note.path,
    ];

    if (diff.changed.isNotEmpty) {
      await index.upsert([for (final note in diff.changed) note.toIndexed()]);
    }
    if (diff.removed.isNotEmpty) {
      await index.removePaths(diff.removed);
    }
    return SyncResult(
      added: added,
      updated: updated,
      removed: diff.removed,
      unchanged: diff.unchanged.length,
    );
  }
}
