import 'semantic_index.dart';
import 'vault_crypto.dart';
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
/// index's cached scan state and applies only the changed subset. When
/// [semanticFactory] is given, its vectors are updated incrementally too:
/// the factory receives exactly the changed notes (so async embedders such as
/// Ollama batch-embed only those chunks, AI-12), unchanged chunks are skipped
/// by hash, and removed notes are dropped. The created index is closed by
/// [VaultSync.apply] itself.
abstract final class VaultSync {
  static Future<SyncResult> apply(
    VaultIndex index,
    String vaultDir, {
    Future<SemanticIndex?> Function(List<ScannedNote> changed)?
        semanticFactory,
    VaultCrypto? crypto,
  }) async {
    final previous = await index.stats();
    final diff = await VaultScanner.diff(vaultDir, previous, crypto: crypto);

    final added = [
      for (final note in diff.changed)
        if (!previous.containsKey(note.path)) note.path,
    ];
    final updated = [
      for (final note in diff.changed)
        if (previous.containsKey(note.path)) note.path,
    ];

    SemanticIndex? semantic;
    try {
      if (diff.changed.isNotEmpty) {
        await index.upsert([for (final note in diff.changed) note.toIndexed()]);
      }
      if (diff.removed.isNotEmpty) {
        await index.removePaths(diff.removed);
      }
      if (semanticFactory != null &&
          (diff.changed.isNotEmpty || diff.removed.isNotEmpty)) {
        semantic = await semanticFactory(diff.changed);
      }
      if (semantic != null && diff.changed.isNotEmpty) {
        await semantic.upsert([
          for (final note in diff.changed)
            for (var i = 0; i < note.parsed.chunks.length; i++)
              ChunkInput(
                notePath: note.path,
                ord: i,
                headingPath: note.parsed.chunks[i].headingPath,
                text: note.parsed.chunks[i].text,
                hash: '${note.contentHash}:$i',
              ),
        ]);
      }
      if (semantic != null && diff.removed.isNotEmpty) {
        await semantic.removeNotes(diff.removed);
      }
    } finally {
      await semantic?.close();
    }
    return SyncResult(
      added: added,
      updated: updated,
      removed: diff.removed,
      unchanged: diff.unchanged.length,
    );
  }
}
