import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'graph_cache.dart';
import 'note_parser.dart';
import 'vault_crypto.dart';

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

  /// Tags per requested path (missing paths are absent from the map) — the
  /// input for tag-based AI access rules (DIF-04).
  Future<Map<String, List<String>>> tagsOf(Set<String> paths);

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


/// Durable JSON index — fallback when native sqlite3 is unavailable.
/// Same interface, same semantics; search is a scored linear scan which is
/// sufficient for tests and small vaults (T1).
class JsonVaultIndex implements VaultIndex, GraphCacheStore {
  JsonVaultIndex(this.filePath, {this.crypto});

  final String filePath;
  final VaultCrypto? crypto;
  final List<IndexedNote> _notes = [];
  bool _loaded = false;
  Map<String, Map<String, Object?>>? _graphCache;

  String get _graphCachePath =>
      p.join(p.dirname(filePath), 'graph_cache.json');

  void _ensureGraphCacheLoaded() {
    if (_graphCache != null) return;
    _graphCache = {};
    final file = File(_graphCachePath);
    if (!file.existsSync()) return;
    try {
      final raw = VaultFiles.readBytes(_graphCachePath, crypto: crypto);
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      for (final entry in decoded.entries) {
        if (entry.value is Map) {
          _graphCache![entry.key] = (entry.value as Map).cast<String, Object?>();
        }
      }
    } on VaultCryptoException {
      _graphCache = {};
      rethrow;
    } catch (_) {
      _graphCache = {};
    }
  }

  Future<void> _flushGraphCache() async {
    await VaultFiles.writeBytes(
      _graphCachePath,
      utf8.encode(jsonEncode(_graphCache)),
      crypto: crypto,
    );
  }

  @override
  Future<void> saveGraphCache({
    required String kind,
    required String version,
    required Map<String, Object?> payload,
  }) async {
    _ensureGraphCacheLoaded();
    _graphCache![kind] = {'version': version, 'payload': payload};
    await _flushGraphCache();
  }

  @override
  Future<Map<String, Object?>?> loadGraphCache({
    required String kind,
    required String version,
  }) async {
    _ensureGraphCacheLoaded();
    final entry = _graphCache![kind];
    if (entry == null || entry['version'] != version) return null;
    return (entry['payload'] as Map?)?.cast<String, Object?>();
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final raw = VaultFiles.readBytes(filePath, crypto: crypto);
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      _notes
        ..clear()
        ..addAll([
          for (final raw in (decoded['notes'] as List? ?? const []))
            IndexedNote.fromJson((raw as Map).cast<String, Object?>()),
        ]);
    } on VaultCryptoException {
      _notes.clear();
      rethrow;
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
    await VaultFiles.writeBytes(
      filePath,
      utf8.encode(jsonEncode({
        'schema_version': 1,
        'notes': [for (final n in _notes) n.toJson()],
      })),
      crypto: crypto,
    );
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
  Future<Map<String, List<String>>> tagsOf(Set<String> paths) async {
    _ensureLoaded();
    if (paths.isEmpty) return const {};
    final out = <String, List<String>>{};
    for (final note in _notes) {
      if (paths.contains(note.path) && note.tags.isNotEmpty) {
        out[note.path] = List.of(note.tags);
      }
    }
    return out;
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
