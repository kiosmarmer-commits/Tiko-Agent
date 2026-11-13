import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'note_parser.dart';
import 'vault_index.dart';

/// One scanned file: stat + hash + parsed content (DATA-10).
class ScannedNote {
  ScannedNote({
    required this.path,
    required this.mtimeNs,
    required this.sizeBytes,
    required this.contentHash,
    required this.parsed,
  });

  final String path;
  final int mtimeNs;
  final int sizeBytes;
  final String contentHash;
  final ParsedNote parsed;

  IndexedNote toIndexed() =>
      IndexedNote.fromParsed(parsed, mtimeNs, sizeBytes, contentHash);
}

/// Walks a vault folder and parses every `.md` file (FR-01: read-only).
abstract final class VaultScanner {
  /// Scans [vaultDir]; skips hidden folders (`.obsidian`, `.simpul`, `.git`).
  static Future<List<ScannedNote>> scan(
    String vaultDir, {
    void Function(String path, int done, int total)? onProgress,
  }) async {
    final files = <File>[];
    await for (final entity in Directory(vaultDir).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.md')) {
        final relative = p.relative(entity.path, from: vaultDir);
        final top = relative.split(RegExp(r'[\\/]')).first;
        if (top.startsWith('.')) continue;
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final notes = <ScannedNote>[];
    var done = 0;
    for (final file in files) {
      final stat = await file.stat();
      final raw = await file.readAsString();
      final hash = sha256.convert(utf8.encode(raw)).toString();
      final relative = p.relative(file.path, from: vaultDir).replaceAll('\\', '/');
      notes.add(ScannedNote(
        path: relative,
        mtimeNs: stat.modified.millisecondsSinceEpoch * 1000000,
        sizeBytes: stat.size,
        contentHash: hash,
        parsed: NoteParser.parse(relative, raw),
      ));
      done++;
      onProgress?.call(relative, done, files.length);
    }
    return notes;
  }

  /// Incremental diff (NFR-S05): returns only notes whose mtime+size changed;
  /// [unchanged] are notes whose cached hash still matches (hash verified
  /// only for the changed subset).
  static Future<ScanDiff> diff(
    String vaultDir,
    Map<String, ({int mtimeNs, int sizeBytes, String hash})> previous,
  ) async {
    final all = await scan(vaultDir);
    final changed = <ScannedNote>[];
    final unchanged = <String>[];
    final removed = previous.keys.toSet();
    for (final note in all) {
      removed.remove(note.path);
      final prev = previous[note.path];
      if (prev == null ||
          prev.mtimeNs != note.mtimeNs ||
          prev.sizeBytes != note.sizeBytes ||
          prev.hash != note.contentHash) {
        changed.add(note);
      } else {
        unchanged.add(note.path);
      }
    }
    return ScanDiff(all: all, changed: changed, unchanged: unchanged, removed: removed.toList());
  }
}

class ScanDiff {
  ScanDiff({
    required this.all,
    required this.changed,
    required this.unchanged,
    required this.removed,
  });

  final List<ScannedNote> all;
  final List<ScannedNote> changed;
  final List<String> unchanged;
  final List<String> removed;
}
