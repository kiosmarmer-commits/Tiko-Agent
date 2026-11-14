import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'graph_cache.dart';
import 'note_parser.dart';
import 'vault_crypto.dart';
import 'vault_index.dart';

/// SQLite-backed index per PRD §3. Returns null when the native sqlite3
/// library is unavailable (same graceful-degradation contract as
/// `SqliteMemoryStore.tryOpen` in agent_memory).
class SqliteVaultIndex implements VaultIndex, GraphCacheStore {
  SqliteVaultIndex._(this.db);

  final Database db;

  static bool _loaderConfigured = false;
  static bool? _sqlcipherAvailable;

  /// Loads the native library once per process. SQLCipher is preferred when
  /// present (it opens plain databases identically and adds PRAGMA key);
  /// Debian/Ubuntu runtime-only installs ship `libsqlite3.so.0` without the
  /// dev symlink, so both names are tried (SEC: sqlite backend).
  static void _ensureLoader() {
    if (_loaderConfigured) return;
    open.overrideFor(OperatingSystem.linux, _loadLinux);
    _loaderConfigured = true;
  }

  static DynamicLibrary _loadLinux() {
    final envPath = Platform.environment['SIMPUL_SQLCIPHER_PATH'];
    final home = Platform.environment['HOME'];
    final candidates = [
      if (envPath != null && envPath.isNotEmpty) envPath,
      if (home != null && home.isNotEmpty) '$home/.local/lib/libsqlcipher.so',
      'libsqlcipher.so',
      'libsqlite3.so',
      'libsqlite3.so.0',
    ];
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('tidak ada libsqlite3/libsqlcipher: $lastError');
  }

  /// True when the loaded native library is SQLCipher (PRAGMA cipher_version
  /// answers), enabling encrypted sqlite backends for locked vaults.
  static bool get sqlcipherAvailable {
    final cached = _sqlcipherAvailable;
    if (cached != null) return cached;
    _ensureLoader();
    try {
      final db = sqlite3.openInMemory();
      try {
        _sqlcipherAvailable = db.select('PRAGMA cipher_version').isNotEmpty;
      } finally {
        db.dispose();
      }
    } catch (_) {
      _sqlcipherAvailable = false;
    }
    return _sqlcipherAvailable!;
  }

  /// SQLCipher-encrypted databases start with a random salt, not the plain
  /// SQLite magic string.
  static bool isFileEncrypted(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final raf = file.openSync();
    try {
      final header = raf.readSync(16);
      return header.length < 16 ||
          utf8.decode(header, allowMalformed: true) != 'SQLite format 3\u0000';
    } finally {
      raf.closeSync();
    }
  }

  static String _hexKey(List<int> vaultKey) =>
      vaultKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Database _openWithKey(String dbPath, List<int> vaultKey) {
    _ensureLoader();
    final db = sqlite3.open(dbPath);
    try {
      db.execute("PRAGMA key = \"x'${_hexKey(vaultKey)}'\"");
      db.select('SELECT count(*) FROM sqlite_master');
      return db;
    } on SqliteException catch (e) {
      db.dispose();
      throw VaultCryptoException(
        'membuka sqlite terenkripsi gagal (kunci salah atau data rusak): '
        '${e.message}',
      );
    }
  }

  /// Re-encrypts a plaintext sqlite database in place via
  /// `sqlcipher_export` (atomic tmp+rename). Returns false when SQLCipher is
  /// unavailable so callers can fail closed.
  static bool encryptFileInPlace(String dbPath, List<int> vaultKey) {
    if (!sqlcipherAvailable) return false;
    _ensureLoader();
    final tmp = '$dbPath.encrypting';
    final plain = sqlite3.open(dbPath);
    try {
      plain.execute(
        "ATTACH DATABASE '$tmp' AS enc KEY \"x'${_hexKey(vaultKey)}'\"");
      plain.select("SELECT sqlcipher_export('enc')");
      plain.execute('DETACH DATABASE enc');
    } finally {
      plain.dispose();
    }
    File(tmp).renameSync(dbPath);
    return true;
  }

  /// Decrypts a SQLCipher database in place via `sqlcipher_export` to a
  /// plaintext tmp file (atomic tmp+rename).
  static void decryptFileInPlace(String dbPath, List<int> vaultKey) {
    _ensureLoader();
    final tmp = '$dbPath.decrypting';
    final encrypted = _openWithKey(dbPath, vaultKey);
    try {
      encrypted.execute("ATTACH DATABASE '$tmp' AS plain KEY ''");
      encrypted.select("SELECT sqlcipher_export('plain')");
      encrypted.execute('DETACH DATABASE plain');
    } finally {
      encrypted.dispose();
    }
    File(tmp).renameSync(dbPath);
  }

  /// Opens the index; pass [vaultKey] (raw vault key bytes) for a
  /// SQLCipher-encrypted database on a locked vault. Returns null when the
  /// native sqlite3 library is unavailable (same graceful-degradation
  /// contract as `SqliteMemoryStore.tryOpen` in agent_memory).
  static SqliteVaultIndex? tryOpen(String dbPath, {List<int>? vaultKey}) {
    try {
      final file = File(dbPath);
      file.parent.createSync(recursive: true);
      final Database db;
      if (vaultKey != null) {
        db = _openWithKey(dbPath, vaultKey);
      } else {
        _ensureLoader();
        db = sqlite3.open(dbPath);
      }
      final index = SqliteVaultIndex._(db);
      index._migrate();
      return index;
    } on VaultCryptoException {
      rethrow;
    } catch (e) {
      stderr.writeln('SqliteVaultIndex unavailable: $e — use JsonVaultIndex');
      return null;
    }
  }

  void _migrate() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS notes (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        mtime_ns INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        word_count INTEGER,
        provenance TEXT NOT NULL DEFAULT 'human',
        ai_access TEXT NOT NULL DEFAULT 'ask',
        indexed_at INTEGER NOT NULL
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_notes_mtime ON notes(mtime_ns)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS graph_layout (
        kind TEXT PRIMARY KEY,
        version TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS links (
        id INTEGER PRIMARY KEY,
        src_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        dst_id INTEGER REFERENCES notes(id) ON DELETE SET NULL,
        dst_raw TEXT NOT NULL,
        kind TEXT NOT NULL,
        anchor TEXT,
        embed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_links_src ON links(src_id)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_links_dst ON links(dst_id)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS tags (
        note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        PRIMARY KEY (note_id, tag)
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS props (
        note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT,
        PRIMARY KEY (note_id, key)
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_props_key_val ON props(key, value)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY,
        note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        ord INTEGER NOT NULL,
        heading_path TEXT,
        start_char INTEGER NOT NULL,
        end_char INTEGER NOT NULL
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_chunks_note ON chunks(note_id)');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        title, heading_path, body
      )
    ''');
  }

  @override
  Future<void> replaceAll(List<IndexedNote> notes) async {
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM chunks_fts');
      db.execute('DELETE FROM chunks');
      db.execute('DELETE FROM props');
      db.execute('DELETE FROM tags');
      db.execute('DELETE FROM links');
      db.execute('DELETE FROM notes');
      _insertAll(notes);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> upsert(List<IndexedNote> notes) async {
    db.execute('BEGIN');
    try {
      final deleteFts = db.prepare(
        'DELETE FROM chunks_fts WHERE rowid IN '
        '(SELECT c.id FROM chunks c JOIN notes n ON n.id = c.note_id WHERE n.path = ?)',
      );
      final deleteNote = db.prepare('DELETE FROM notes WHERE path = ?');
      for (final note in notes) {
        deleteFts.execute([note.path]);
        deleteNote.execute([note.path]);
      }
      deleteFts.dispose();
      deleteNote.dispose();
      _insertAll(notes);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> removePaths(List<String> paths) async {
    db.execute('BEGIN');
    try {
      final deleteFts = db.prepare(
        'DELETE FROM chunks_fts WHERE rowid IN '
        '(SELECT c.id FROM chunks c JOIN notes n ON n.id = c.note_id WHERE n.path = ?)',
      );
      final deleteNote = db.prepare('DELETE FROM notes WHERE path = ?');
      for (final path in paths) {
        deleteFts.execute([path]);
        deleteNote.execute([path]);
      }
      deleteFts.dispose();
      deleteNote.dispose();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insertAll(List<IndexedNote> notes) {
    final ids = <String, int>{};
    final byBasename = <String, String>{};
    final byPath = <String, String>{};
    for (final row in db.select('SELECT id, path FROM notes')) {
      final path = row['path'] as String;
      ids[path] = row['id'] as int;
      final withoutExt = path.replaceAll(RegExp(r'\.md$'), '');
      byPath[withoutExt] = path;
      byBasename.putIfAbsent(p.basename(withoutExt), () => path);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final insertNote = db.prepare(
      'INSERT INTO notes (path, title, mtime_ns, size_bytes, content_hash, word_count, provenance, ai_access, indexed_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    for (final note in notes) {
      insertNote.execute([
        note.path,
        note.title,
        note.mtimeNs,
        note.sizeBytes,
        note.contentHash,
        note.wordCount,
        note.provenance,
        note.aiAccess,
        now,
      ]);
      final noteId = db.lastInsertRowId;
      ids[note.path] = noteId;
      final withoutExt = note.path.replaceAll(RegExp(r'\.md$'), '');
      byPath[withoutExt] = note.path;
      byBasename.putIfAbsent(p.basename(withoutExt), () => note.path);

      for (final tag in note.tags) {
        db.execute('INSERT INTO tags (note_id, tag) VALUES (?, ?)', [noteId, tag]);
      }
      for (final entry in note.props.entries) {
        db.execute('INSERT INTO props (note_id, key, value) VALUES (?, ?, ?)', [
          noteId,
          entry.key,
          entry.value?.toString(),
        ]);
      }
      for (var i = 0; i < note.chunks.length; i++) {
        final chunk = note.chunks[i];
        db.execute(
          'INSERT INTO chunks (note_id, ord, heading_path, start_char, end_char) VALUES (?, ?, ?, ?, ?)',
          [noteId, i, chunk.headingPath, chunk.startChar, chunk.endChar],
        );
        db.execute(
          'INSERT INTO chunks_fts (rowid, title, heading_path, body) VALUES (?, ?, ?, ?)',
          [db.lastInsertRowId, note.title, chunk.headingPath, chunk.text],
        );
      }
    }
    insertNote.dispose();

    final insertLink = db.prepare(
      'INSERT INTO links (src_id, dst_id, dst_raw, kind, anchor, embed) VALUES (?, ?, ?, ?, ?, ?)',
    );
    final resolved = <String, int>{};
    for (final note in notes) {
      final srcId = ids[note.path]!;
      for (final link in note.links) {
        if (link.target.isEmpty) continue;
        var dstId = resolved[link.target];
        if (dstId == null) {
          final targetPath = resolveTarget(link.target, byBasename, byPath);
          dstId = targetPath == null ? null : ids[targetPath];
          resolved[link.target] = dstId ?? -1;
        }
        insertLink.execute([
          srcId,
          (dstId != null && dstId > 0) ? dstId : null,
          link.target,
          link.kind,
          link.anchor,
          link.embed ? 1 : 0,
        ]);
      }
    }
    insertLink.dispose();
  }

  @override
  Future<Map<String, ({int mtimeNs, int sizeBytes, String hash})>> stats() async {
    return {
      for (final row in db.select(
        'SELECT path, mtime_ns, size_bytes, content_hash FROM notes',
      ))
        row['path'] as String: (
          mtimeNs: row['mtime_ns'] as int,
          sizeBytes: row['size_bytes'] as int,
          hash: row['content_hash'] as String,
        ),
    };
  }

  @override
  Future<void> saveGraphCache({
    required String kind,
    required String version,
    required Map<String, Object?> payload,
  }) async {
    db.execute(
      'INSERT OR REPLACE INTO graph_layout (kind, version, payload, created_at) '
      'VALUES (?, ?, ?, ?)',
      [kind, version, jsonEncode(payload), DateTime.now().millisecondsSinceEpoch],
    );
  }

  @override
  Future<Map<String, Object?>?> loadGraphCache({
    required String kind,
    required String version,
  }) async {
    final rows = db.select(
      'SELECT version, payload FROM graph_layout WHERE kind = ?',
      [kind],
    );
    if (rows.isEmpty || rows.first['version'] != version) return null;
    return (jsonDecode(rows.first['payload'] as String) as Map)
        .cast<String, Object?>();
  }

  @override
  Future<List<SearchHit>> search(String query, {int limit = 20}) async {
    final parsed = SearchQuery.parse(query);
    if (parsed.isEmpty) return const [];
    if (parsed.terms.isEmpty && parsed.phrases.isEmpty) {
      return _filterOnly(parsed, limit);
    }
    final match = _ftsMatch(parsed);
    final rows = db.select(
      '''
      SELECT n.path, n.title, c.heading_path,
             snippet(chunks_fts, 2, '»', '«', '…', 12) AS snip,
             bm25(chunks_fts) AS rank
      FROM chunks_fts
      JOIN chunks c ON c.id = chunks_fts.rowid
      JOIN notes n ON n.id = c.note_id
      WHERE chunks_fts MATCH ?
      ORDER BY rank
      LIMIT ?
      ''',
      [match, limit * 4],
    );
    final hits = <SearchHit>[];
    for (final row in rows) {
      final path = row['path'] as String;
      if (!_passesFilters(parsed, path, title: row['title'] as String)) continue;
      hits.add(SearchHit(
        path: path,
        title: row['title'] as String,
        headingPath: (row['heading_path'] as String?) ?? '',
        score: ((row['rank'] as num?)?.toDouble() ?? 0).abs(),
        snippet: (row['snip'] as String?) ?? '',
      ));
      if (hits.length >= limit) break;
    }
    return hits;
  }

  String _ftsMatch(SearchQuery parsed) {
    final parts = <String>[];
    for (final term in parsed.terms) {
      parts.add('"${term.replaceAll('"', '""')}"');
    }
    for (final phrase in parsed.phrases) {
      parts.add('"${phrase.replaceAll('"', '""')}"');
    }
    var match = parts.join(' AND ');
    for (final exclusion in parsed.exclusions) {
      final neg = '"${exclusion.replaceAll('"', '""')}"';
      match = match.isEmpty ? 'NOT $neg' : '$match NOT $neg';
    }
    return match.isEmpty ? '""' : match;
  }

  Future<List<SearchHit>> _filterOnly(SearchQuery parsed, int limit) async {
    final rows = db.select('SELECT path, title FROM notes ORDER BY path');
    final hits = <SearchHit>[];
    for (final row in rows) {
      final path = row['path'] as String;
      if (!_passesFilters(parsed, path, title: row['title'] as String)) continue;
      hits.add(SearchHit(path: path, title: row['title'] as String, score: 1, snippet: ''));
      if (hits.length >= limit) break;
    }
    return hits;
  }

  bool _passesFilters(SearchQuery parsed, String path, {required String title}) {
    for (final pathFilter in parsed.paths) {
      if (!path.toLowerCase().contains(pathFilter)) return false;
    }
    if (parsed.tags.isNotEmpty || parsed.propFilters.isNotEmpty) {
      final noteId = db.select('SELECT id FROM notes WHERE path = ?', [path]).firstOrNull?['id'];
      if (noteId == null) return false;
      for (final tag in parsed.tags) {
        final found = db.select(
          'SELECT 1 FROM tags WHERE note_id = ? AND tag = ?',
          [noteId, tag],
        );
        final prefix = db.select(
          "SELECT 1 FROM tags WHERE note_id = ? AND (tag = ? OR tag LIKE ? || '/%')",
          [noteId, tag, tag],
        );
        if (found.isEmpty && prefix.isEmpty) return false;
      }
      for (final (key, value) in parsed.propFilters) {
        final row = db.select(
          'SELECT value FROM props WHERE note_id = ? AND key = ?',
          [noteId, key],
        ).firstOrNull;
        if (row == null) return false;
        if (value != null && (row['value']?.toString().toLowerCase() ?? '') != value) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  Future<List<String>> backlinks(String notePath) async {
    final rows = db.select('''
      SELECT DISTINCT src.path FROM links l
      JOIN notes dst ON dst.id = l.dst_id
      JOIN notes src ON src.id = l.src_id
      WHERE dst.path = ?
      ORDER BY src.path
    ''', [notePath]);
    return [for (final row in rows) row['path'] as String];
  }

  @override
  Future<IndexedNote?> noteByPath(String path) async {
    final noteRows = db.select(
      'SELECT * FROM notes WHERE path = ? LIMIT 1',
      [path],
    );
    if (noteRows.isEmpty) return null;
    final row = noteRows.first;
    final noteId = row['id'] as int;
    final tags = [
      for (final t in db.select(
        'SELECT tag FROM tags WHERE note_id = ? ORDER BY tag',
        [noteId],
      ))
        t['tag'] as String,
    ];
    final props = {
      for (final pr in db.select(
        'SELECT key, value FROM props WHERE note_id = ? ORDER BY key',
        [noteId],
      ))
        pr['key'] as String: pr['value'],
    };
    final links = [
      for (final l in db.select(
        'SELECT dst_raw, kind, anchor, embed FROM links '
        'WHERE src_id = ? ORDER BY rowid',
        [noteId],
      ))
        ParsedLink(
          target: l['dst_raw'] as String,
          anchor: l['anchor'] as String? ?? '',
          alias: '',
          kind: l['kind'] as String? ?? 'wikilink',
          embed: (l['embed'] as int? ?? 0) == 1,
          offset: 0,
        ),
    ];
    final chunks = [
      for (final c in db.select(
        'SELECT c.heading_path, c.start_char, c.end_char, f.body '
        'FROM chunks c JOIN chunks_fts f ON f.rowid = c.id '
        'WHERE c.note_id = ? ORDER BY c.ord',
        [noteId],
      ))
        NoteChunk(
          headingPath: c['heading_path'] as String? ?? '',
          startChar: c['start_char'] as int,
          endChar: c['end_char'] as int,
          text: c['body'] as String? ?? '',
        ),
    ];
    return IndexedNote(
      path: row['path'] as String,
      title: row['title'] as String,
      mtimeNs: row['mtime_ns'] as int,
      sizeBytes: row['size_bytes'] as int,
      contentHash: row['content_hash'] as String,
      wordCount: (row['word_count'] as num?)?.toInt() ?? 0,
      props: props,
      tags: tags,
      aliases: const [],
      links: links,
      chunks: chunks,
      provenance: row['provenance'] as String? ?? 'human',
      aiAccess: row['ai_access'] as String? ?? 'ask',
    );
  }

  @override
  Future<Map<String, List<String>>> tagsOf(Set<String> paths) async {
    if (paths.isEmpty) return const {};
    final placeholders = List.filled(paths.length, '?').join(', ');
    final rows = db.select(
      'SELECT n.path AS path, t.tag AS tag FROM tags t '
      'JOIN notes n ON n.id = t.note_id '
      'WHERE n.path IN ($placeholders) ORDER BY n.path, t.tag',
      paths.toList(),
    );
    final out = <String, List<String>>{};
    for (final row in rows) {
      out.putIfAbsent(row['path'] as String, () => []).add(row['tag'] as String);
    }
    return out;
  }

  @override
  Future<VaultHealthReport> health() async {
    final noteCount = db.select('SELECT COUNT(*) AS n FROM notes').first['n'] as int;
    final linkCount = db.select('SELECT COUNT(*) AS n FROM links').first['n'] as int;
    final broken = <String, int>{};
    for (final row in db.select(
      'SELECT dst_raw, COUNT(*) AS n FROM links WHERE dst_id IS NULL GROUP BY dst_raw',
    )) {
      broken[row['dst_raw'] as String] = row['n'] as int;
    }
    final orphans = [
      for (final row in db.select(
        '''
        SELECT path FROM notes n
        WHERE NOT EXISTS (SELECT 1 FROM links l WHERE l.dst_id = n.id)
          AND NOT EXISTS (SELECT 1 FROM links l WHERE l.src_id = n.id)
        ORDER BY path
        ''',
      ))
        row['path'] as String,
    ];
    final dupes = <String, int>{};
    for (final row in db.select(
      'SELECT title, COUNT(*) AS n FROM notes GROUP BY title HAVING COUNT(*) > 1',
    )) {
      dupes[row['title'] as String] = row['n'] as int;
    }
    return VaultHealthReport(
      noteCount: noteCount,
      linkCount: linkCount,
      brokenLinks: broken,
      orphans: orphans,
      duplicateTitles: dupes,
    );
  }

  @override
  Future<void> close() async => db.dispose();
}
