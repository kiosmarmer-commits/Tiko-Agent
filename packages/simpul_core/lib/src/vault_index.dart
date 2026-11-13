import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'note_parser.dart';

/// One indexed note row (PRD DATA-03 `notes` + derived rows).
class IndexedNote {
  const IndexedNote({
    required this.path,
    required this.title,
    required this.mtimeNs,
    required this.sizeBytes,
    required this.contentHash,
    required this.wordCount,
    required this.props,
    required this.tags,
    required this.aliases,
    required this.links,
    required this.chunks,
    this.provenance = 'human',
    this.aiAccess = 'ask',
  });

  final String path;
  final String title;
  final int mtimeNs;
  final int sizeBytes;
  final String contentHash;
  final int wordCount;
  final Map<String, Object?> props;
  final List<String> tags;
  final List<String> aliases;
  final List<ParsedLink> links;
  final List<NoteChunk> chunks;
  final String provenance;
  final String aiAccess;

  static IndexedNote fromParsed(ParsedNote note, int mtimeNs, int sizeBytes, String hash) =>
      IndexedNote(
        path: note.path,
        title: note.title,
        mtimeNs: mtimeNs,
        sizeBytes: sizeBytes,
        contentHash: hash,
        wordCount: note.wordCount,
        props: note.props,
        tags: note.tags,
        aliases: note.aliases,
        links: note.links,
        chunks: note.chunks,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'title': title,
        'mtime_ns': mtimeNs,
        'size_bytes': sizeBytes,
        'content_hash': contentHash,
        'word_count': wordCount,
        'props': props,
        'tags': tags,
        'aliases': aliases,
        'links': [
          for (final l in links)
            {
              'target': l.target,
              'anchor': l.anchor,
              'alias': l.alias,
              'kind': l.kind,
              'embed': l.embed,
            },
        ],
        'chunks': [
          for (final c in chunks)
            {
              'heading_path': c.headingPath,
              'start_char': c.startChar,
              'end_char': c.endChar,
              'text': c.text,
            },
        ],
        'provenance': provenance,
        'ai_access': aiAccess,
      };

  static IndexedNote fromJson(Map<String, Object?> json) {
    final rawLinks = (json['links'] as List? ?? const []);
    final rawChunks = (json['chunks'] as List? ?? const []);
    return IndexedNote(
      path: json['path']!.toString(),
      title: json['title']!.toString(),
      mtimeNs: (json['mtime_ns'] as num?)?.toInt() ?? 0,
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      contentHash: json['content_hash']!.toString(),
      wordCount: (json['word_count'] as num?)?.toInt() ?? 0,
      props: (json['props'] as Map?)?.cast<String, Object?>() ?? {},
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      aliases: (json['aliases'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      links: [
        for (final l in rawLinks)
          ParsedLink(
            target: l['target']?.toString() ?? '',
            anchor: l['anchor']?.toString() ?? '',
            alias: l['alias']?.toString() ?? '',
            kind: l['kind']?.toString() ?? 'wikilink',
            embed: l['embed'] == true,
            offset: 0,
          ),
      ],
      chunks: [
        for (final c in rawChunks)
          NoteChunk(
            headingPath: c['heading_path']?.toString() ?? '',
            startChar: (c['start_char'] as num?)?.toInt() ?? 0,
            endChar: (c['end_char'] as num?)?.toInt() ?? 0,
            text: c['text']?.toString() ?? '',
          ),
      ],
      provenance: json['provenance']?.toString() ?? 'human',
      aiAccess: json['ai_access']?.toString() ?? 'ask',
    );
  }
}

/// One search hit with a highlighted snippet (FR-35).
class SearchHit {
  const SearchHit({
    required this.path,
    required this.title,
    required this.score,
    required this.snippet,
    this.headingPath = '',
  });

  final String path;
  final String title;
  final double score;
  final String snippet;
  final String headingPath;
}

/// Vault health findings (DIF-08 subset for P0).
class VaultHealthReport {
  const VaultHealthReport({
    required this.noteCount,
    required this.linkCount,
    required this.brokenLinks,
    required this.orphans,
    required this.duplicateTitles,
  });

  final int noteCount;
  final int linkCount;
  final Map<String, int> brokenLinks;
  final List<String> orphans;
  final Map<String, int> duplicateTitles;
}

/// Durable vault index (PRD `09-arsitektur-data.md` §3).
abstract class VaultIndex {
  Future<void> replaceAll(List<IndexedNote> notes);

  /// Incremental update (NFR-08): inserts or replaces notes by path; children
  /// (links/tags/props/chunks) of replaced notes are rebuilt.
  Future<void> upsert(List<IndexedNote> notes);

  /// Removes notes by path together with their derived rows.
  Future<void> removePaths(List<String> paths);

  /// Cached scan state per path (NFR-S05) — the input for incremental diff.
  Future<Map<String, ({int mtimeNs, int sizeBytes, String hash})>> stats();
  Future<List<SearchHit>> search(String query, {int limit = 20});
  Future<List<String>> backlinks(String notePath);
  Future<VaultHealthReport> health();
  Future<void> close();
}

/// Resolves a link target to a note path. Obsidian resolves by basename
/// anywhere in the vault (shortest path wins) or by exact vault-relative path.
String? resolveTarget(String target, Map<String, String> byBasename, Map<String, String> byPath) {
  final stripped = target.replaceAll(RegExp(r'\.md$'), '');
  final direct = byPath[target] ?? byPath['$target.md'] ?? byPath[stripped];
  if (direct != null) return direct;
  return byBasename[target] ?? byBasename['$target.md'] ?? byBasename[stripped];
}

/// Parses a search query (FR-30): `tag:`, `path:`, `prop:key=value`,
/// `"phrase"`, `-exclude`, plain terms (AND).
class SearchQuery {
  SearchQuery.parse(String input)
      : terms = [],
        phrases = [],
        exclusions = [],
        tags = [],
        paths = [],
        propFilters = [] {
    final tokenPattern = RegExp(r'-"[^"]*"|"[^"]*"|\S+');
    for (final m in tokenPattern.allMatches(input)) {
      final token = m.group(0)!;
      if (token.startsWith('-"') && token.endsWith('"') && token.length > 2) {
        exclusions.add(token.substring(2, token.length - 1).toLowerCase());
      } else if (token.startsWith('"') && token.endsWith('"') && token.length > 2) {
        phrases.add(token.substring(1, token.length - 1).toLowerCase());
      } else if (token.startsWith('-') && token.length > 1) {
        exclusions.add(token.substring(1).toLowerCase());
      } else if (token.startsWith('tag:')) {
        final value = token.substring(4).trim();
        if (value.isNotEmpty) tags.add(value.toLowerCase());
      } else if (token.startsWith('path:')) {
        final value = token.substring(5).trim();
        if (value.isNotEmpty) paths.add(value.toLowerCase());
      } else if (token.startsWith('prop:')) {
        final value = token.substring(5).trim();
        final eq = value.indexOf('=');
        if (eq > 0) {
          propFilters.add((value.substring(0, eq).toLowerCase(), value.substring(eq + 1).toLowerCase()));
        } else if (value.isNotEmpty) {
          propFilters.add((value.toLowerCase(), null));
        }
      } else if (token.trim().isNotEmpty) {
        terms.add(token.trim().toLowerCase());
      }
    }
  }

  final List<String> terms;
  final List<String> phrases;
  final List<String> exclusions;
  final List<String> tags;
  final List<String> paths;
  final List<(String key, String? value)> propFilters;

  bool get isEmpty =>
      terms.isEmpty && phrases.isEmpty && tags.isEmpty && paths.isEmpty && propFilters.isEmpty;
}

/// SQLite-backed index per PRD §3. Returns null when the native sqlite3
/// library is unavailable (same graceful-degradation contract as
/// `SqliteMemoryStore.tryOpen` in agent_memory).
class SqliteVaultIndex implements VaultIndex {
  SqliteVaultIndex._(this.db);

  final Database db;

  static SqliteVaultIndex? tryOpen(String dbPath) {
    try {
      final file = File(dbPath);
      file.parent.createSync(recursive: true);
      final db = sqlite3.open(dbPath);
      final index = SqliteVaultIndex._(db);
      index._migrate();
      return index;
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

/// Durable JSON index — fallback when native sqlite3 is unavailable.
/// Same interface, same semantics; search is a scored linear scan which is
/// sufficient for tests and small vaults (T1).
class JsonVaultIndex implements VaultIndex {
  JsonVaultIndex(this.filePath);

  final String filePath;
  final List<IndexedNote> _notes = [];
  bool _loaded = false;

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      _notes
        ..clear()
        ..addAll([
          for (final raw in (decoded['notes'] as List? ?? const []))
            IndexedNote.fromJson((raw as Map).cast<String, Object?>()),
        ]);
    } catch (_) {
      _notes.clear();
    }
  }

  @override
  Future<void> replaceAll(List<IndexedNote> notes) async {
    _loaded = true;
    _notes
      ..clear()
      ..addAll(notes);
    await _flush();
  }

  @override
  Future<void> upsert(List<IndexedNote> notes) async {
    _ensureLoaded();
    final indexByPath = {
      for (var i = 0; i < _notes.length; i++) _notes[i].path: i,
    };
    for (final note in notes) {
      final existing = indexByPath[note.path];
      if (existing != null) {
        _notes[existing] = note;
      } else {
        indexByPath[note.path] = _notes.length;
        _notes.add(note);
      }
    }
    await _flush();
  }

  @override
  Future<void> removePaths(List<String> paths) async {
    _ensureLoaded();
    final removed = paths.toSet();
    _notes.removeWhere((note) => removed.contains(note.path));
    await _flush();
  }

  Future<void> _flush() async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final tmp = '$filePath.tmp';
    await File(tmp).writeAsString(jsonEncode({
      'schema_version': 1,
      'notes': [for (final n in _notes) n.toJson()],
    }));
    await File(tmp).rename(filePath);
  }

  List<IndexedNote> _resolvedInbound() {
    final byBasename = <String, String>{};
    final byPath = <String, String>{};
    for (final note in _notes) {
      byPath[note.path] = note.path;
      byBasename.putIfAbsent(
        p.basename(note.path).replaceAll(RegExp(r'\.md$'), ''),
        () => note.path,
      );
    }
    return _notes;
  }

  Map<String, String> _byBasename() {
    final map = <String, String>{};
    for (final note in _notes) {
      map.putIfAbsent(
        p.basename(note.path).replaceAll(RegExp(r'\.md$'), ''),
        () => note.path,
      );
    }
    return map;
  }

  Map<String, String> _byPath() => {
        for (final note in _notes) note.path.replaceAll(RegExp(r'\.md$'), ''): note.path,
      };

  @override
  Future<Map<String, ({int mtimeNs, int sizeBytes, String hash})>> stats() async {
    _ensureLoaded();
    return {
      for (final note in _notes)
        note.path: (
          mtimeNs: note.mtimeNs,
          sizeBytes: note.sizeBytes,
          hash: note.contentHash,
        ),
    };
  }

  @override
  Future<List<SearchHit>> search(String query, {int limit = 20}) async {
    _ensureLoaded();
    final parsed = SearchQuery.parse(query);
    final hits = <SearchHit>[];
    for (final note in _resolvedInbound()) {
      if (!_passesFilters(parsed, note)) continue;
      final scoreAndSnippet = _score(note, parsed);
      if (scoreAndSnippet == null) continue;
      hits.add(SearchHit(
        path: note.path,
        title: note.title,
        score: scoreAndSnippet.$1,
        snippet: scoreAndSnippet.$2,
        headingPath: scoreAndSnippet.$3,
      ));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  bool _passesFilters(SearchQuery parsed, IndexedNote note) {
    final lowerPath = note.path.toLowerCase();
    for (final pathFilter in parsed.paths) {
      if (!lowerPath.contains(pathFilter)) return false;
    }
    for (final tag in parsed.tags) {
      final found = note.tags.any(
        (t) => t.toLowerCase() == tag || t.toLowerCase().startsWith('$tag/'),
      );
      if (!found) return false;
    }
    for (final (key, value) in parsed.propFilters) {
      final actual = note.props[key];
      if (actual == null) return false;
      if (value != null && actual.toString().toLowerCase() != value) return false;
    }
    return true;
  }

  (double, String, String)? _score(IndexedNote note, SearchQuery parsed) {
    if (parsed.isEmpty) return null;
    final haystackTitle = note.title.toLowerCase();
    var score = 0.0;
    var bestSnippet = '';
    var bestHeading = '';

    for (final term in parsed.terms) {
      var termScore = 0.0;
      if (haystackTitle.contains(term)) termScore += 3.0;
      for (final chunk in note.chunks) {
        final lower = chunk.text.toLowerCase();
        final occurrences = term.allMatches(lower).length;
        if (occurrences > 0) {
          termScore += occurrences.toDouble();
          if (bestSnippet.isEmpty) {
            bestSnippet = _snippet(chunk.text, term);
            bestHeading = chunk.headingPath;
          }
        }
      }
      if (termScore == 0) return null;
      score += termScore;
    }

    for (final phrase in parsed.phrases) {
      var phraseScore = 0.0;
      if (haystackTitle.contains(phrase)) phraseScore += 3.0;
      for (final chunk in note.chunks) {
        final lower = chunk.text.toLowerCase();
        if (lower.contains(phrase)) {
          phraseScore += 2.0;
          if (bestSnippet.isEmpty) {
            bestSnippet = _snippet(chunk.text, phrase);
            bestHeading = chunk.headingPath;
          }
        }
      }
      if (phraseScore == 0) return null;
      score += phraseScore;
    }

    for (final exclusion in parsed.exclusions) {
      if (haystackTitle.contains(exclusion)) return null;
      for (final chunk in note.chunks) {
        if (chunk.text.toLowerCase().contains(exclusion)) return null;
      }
    }
    return (score, bestSnippet, bestHeading);
  }

  String _snippet(String text, String needle) {
    final lower = text.toLowerCase();
    final index = lower.indexOf(needle);
    if (index < 0) return text.trim().substring(0, text.trim().length.clamp(0, 80));
    final start = (index - 40).clamp(0, text.length);
    final end = (index + needle.length + 60).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end).trim()}$suffix';
  }

  @override
  Future<List<String>> backlinks(String notePath) async {
    _ensureLoaded();
    final byBasename = _byBasename();
    final byPath = _byPath();
    final resolved = resolveTarget(
      notePath.replaceAll(RegExp(r'\.md$'), ''),
      byBasename,
      byPath,
    );
    if (resolved == null) return const [];
    final sources = <String>{};
    for (final note in _notes) {
      for (final link in note.links) {
        if (resolveTarget(link.target, byBasename, byPath) == resolved) {
          sources.add(note.path);
        }
      }
    }
    return sources.toList()..sort();
  }

  @override
  Future<VaultHealthReport> health() async {
    _ensureLoaded();
    final byBasename = _byBasename();
    final byPath = _byPath();
    final inbound = <String, int>{};
    final outbound = <String, int>{};
    final broken = <String, int>{};
    var linkCount = 0;
    for (final note in _notes) {
      for (final link in note.links) {
        if (link.target.isEmpty) continue;
        linkCount++;
        outbound[note.path] = (outbound[note.path] ?? 0) + 1;
        final resolved = resolveTarget(link.target, byBasename, byPath);
        if (resolved == null) {
          broken[link.target] = (broken[link.target] ?? 0) + 1;
        } else {
          inbound[resolved] = (inbound[resolved] ?? 0) + 1;
        }
      }
    }
    final orphans = [
      for (final note in _notes)
        if (!inbound.containsKey(note.path) && !outbound.containsKey(note.path)) note.path,
    ]..sort();
    final titles = <String, int>{};
    for (final note in _notes) {
      titles[note.title] = (titles[note.title] ?? 0) + 1;
    }
    final dupes = {
      for (final e in titles.entries)
        if (e.value > 1) e.key: e.value,
    };
    return VaultHealthReport(
      noteCount: _notes.length,
      linkCount: linkCount,
      brokenLinks: broken,
      orphans: orphans,
      duplicateTitles: dupes,
    );
  }

  @override
  Future<void> close() async {}
}
