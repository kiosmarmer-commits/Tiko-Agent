import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simpul_core/simpul_core.dart';

/// MCP stdio bridge ("Simpul Bridge", AI-44): exposes a local vault to an MCP
/// client over newline-delimited JSON-RPC 2.0 on stdin/stdout. There is no
/// network listener at all; when [token] is set, every request must carry it
/// under `params._meta.token` (fail-closed).
class SimpulBridge {
  SimpulBridge({required this.vaultDir, this.token});

  final String vaultDir;
  final String? token;

  static const _maxReadChars = 20000;

  VaultIndex? _index;

  Future<String> handleLine(String line) async {
    Object? id;
    try {
      final message = jsonDecode(line) as Map<String, Object?>;
      id = message['id'];
      if (message['jsonrpc'] != '2.0') {
        return _error(id, -32600, 'jsonrpc harus "2.0"');
      }
      final method = message['method'];
      if (method is! String) {
        return _error(id, -32600, 'method wajib string');
      }
      final params =
          (message['params'] as Map?)?.cast<String, Object?>() ?? const {};

      if (token != null) {
        final meta = (params['_meta'] as Map?)?.cast<String, Object?>();
        if (meta == null || meta['token'] != token) {
          return _error(id, -32001, 'token akses tidak valid');
        }
      }

      switch (method) {
        case 'initialize':
          return _result(id, {
            'protocolVersion': '2024-11-05',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'simpul-bridge', 'version': '0.1.0'},
          });
        case 'notifications/initialized':
        case 'notifications/cancelled':
          return '';
        case 'ping':
          return _result(id, {});
        case 'tools/list':
          return _result(id, {'tools': _toolDescriptors()});
        case 'tools/call':
          return await _callTool(id, params);
        default:
          return _error(id, -32601, 'method tidak dikenal: $method');
      }
    } on FormatException catch (e) {
      return _error(id, -32700, 'JSON tidak valid: ${e.message}');
    } catch (e) {
      return _error(id, -32603, 'kesalahan internal: $e');
    }
  }

  Future<String> _callTool(Object? id, Map<String, Object?> params) async {
    final name = params['name'];
    if (name is! String) {
      return _error(id, -32602, 'name tool wajib string');
    }
    final args =
        (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
    try {
      final data = await switch (name) {
        'search' => _search(args),
        'semsearch' => _semsearch(args),
        'health' => _health(),
        'backlinks' => _backlinks(args),
        'read_note' => _readNote(args),
        'clusters' => _clusters(),
        'suggest_links' => _suggestLinks(args),
        _ => throw ArgumentError('tool tidak dikenal: $name'),
      };
      return _result(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(data)},
        ],
      });
    } on ArgumentError catch (e) {
      return _result(id, {
        'content': [
          {'type': 'text', 'text': '${e.message}'},
        ],
        'isError': true,
      });
    } catch (e) {
      return _result(id, {
        'content': [
          {'type': 'text', 'text': 'gagal: $e'},
        ],
        'isError': true,
      });
    }
  }

  Future<VaultIndex> _openIndex() async {
    final existing = _index;
    if (existing != null) return existing;
    final dir = p.join(vaultDir, '.simpul');
    final sqlite = SqliteVaultIndex.tryOpen(p.join(dir, 'index.db'));
    final VaultIndex index = sqlite ?? JsonVaultIndex(p.join(dir, 'index.json'));
    _index = index;
    return index;
  }

  Future<Object?> _search(Map<String, Object?> args) async {
    final query = args['query'];
    if (query is! String || query.isEmpty) {
      throw ArgumentError('query wajib string non-kosong');
    }
    final index = await _openIndex();
    final hits = await index.search(query, limit: _intArg(args, 'limit', 20));
    return {
      'query': query,
      'hits': [
        for (final h in hits)
          {'path': h.path, 'score': h.score, 'snippet': h.snippet},
      ],
    };
  }

  Future<Object?> _semsearch(Map<String, Object?> args) async {
    final query = args['query'];
    if (query is! String || query.isEmpty) {
      throw ArgumentError('query wajib string non-kosong');
    }
    final vectorsFile = File(p.join(vaultDir, '.simpul', 'vectors.json'));
    if (!vectorsFile.existsSync()) {
      throw StateError(
        'indeks vektor belum ada — jalankan: simpul index "$vaultDir" --embed',
      );
    }
    final embedder = HashingEmbedder();
    final semantic = InMemorySemanticIndex(
      embedder,
      filePath: vectorsFile.path,
    );
    try {
      final hits = await semantic.search(
        embedder.embed(query),
        limit: _intArg(args, 'limit', 20),
      );
      return {
        'query': query,
        'model': embedder.modelVersion,
        'hits': [
          for (final h in hits)
            {
              'path': h.notePath,
              'chunk': h.ord,
              'heading_path': h.headingPath,
              'score': h.score,
            },
        ],
      };
    } finally {
      await semantic.close();
    }
  }

  Future<Object?> _health() async {
    final index = await _openIndex();
    final report = await index.health();
    return {
      'note_count': report.noteCount,
      'link_count': report.linkCount,
      'broken_links': report.brokenLinks,
      'orphans': report.orphans,
      'duplicate_titles': report.duplicateTitles,
    };
  }

  Future<Object?> _backlinks(Map<String, Object?> args) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw ArgumentError('path wajib string non-kosong');
    }
    final index = await _openIndex();
    return {'path': path, 'backlinks': await index.backlinks(path)};
  }

  Future<Object?> _readNote(Map<String, Object?> args) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw ArgumentError('path wajib string non-kosong');
    }
    final canonicalVault = p.canonicalize(vaultDir);
    final requested = p.canonicalize(p.join(vaultDir, path));
    if (requested != canonicalVault && !p.isWithin(canonicalVault, requested)) {
      throw ArgumentError('path keluar dari vault: $path');
    }
    final file = File(requested);
    if (!file.existsSync()) {
      throw StateError('catatan tidak ditemukan: $path');
    }
    var text = file.readAsStringSync();
    if (text.length > _maxReadChars) {
      text = text.substring(0, _maxReadChars);
    }
    return {'path': path, 'content': text};
  }

  Future<Object?> _clusters() async {
    final notes = await VaultScanner.scan(vaultDir);
    final graph = GraphCsr.build(notes.map((n) => n.toIndexed()).toList());
    final result = CommunityDetector.louvain(graph);
    final sizes = <int, int>{};
    for (final c in result.communityOf) {
      sizes[c] = (sizes[c] ?? 0) + 1;
    }
    return {
      'community_count': result.communityCount,
      'modularity': result.modularity,
      'sizes': Map.fromEntries(
        (sizes.keys.toList()..sort()).map((c) => MapEntry('$c', sizes[c]!)),
      ),
    };
  }

  Future<Object?> _suggestLinks(Map<String, Object?> args) async {
    final notes = await VaultScanner.scan(vaultDir);
    final suggestions = await LinkSuggester.suggest(
      notes.map((n) => n.toIndexed()).toList(),
      limit: _intArg(args, 'limit', 20),
      minScore: _doubleArg(args, 'min_score', LinkSuggester.defaultMinScore),
    );
    return {
      'suggestions': [
        for (final s in suggestions)
          {'from': s.fromPath, 'to': s.toPath, 'score': s.score},
      ],
    };
  }

  static int _intArg(Map<String, Object?> args, String key, int fallback) {
    final value = args[key];
    return value is int ? value : fallback;
  }

  static double _doubleArg(Map<String, Object?> args, String key, double fallback) {
    final value = args[key];
    return value is num ? value.toDouble() : fallback;
  }

  static List<Map<String, Object?>> _toolDescriptors() => [
        _tool('search', 'Pencarian leksikal vault (BM25/AND, dukungan tag:, path:, prop:)', {
          'query': {'type': 'string'},
          'limit': {'type': 'integer'},
        }, ['query']),
        _tool('semsearch', 'Pencarian semantik atas indeks vektor lokal', {
          'query': {'type': 'string'},
          'limit': {'type': 'integer'},
        }, ['query']),
        _tool('health', 'Laporan kesehatan vault (tautan rusak, orphan, judul ganda)', {}, []),
        _tool('backlinks', 'Daftar backlink ke sebuah catatan', {
          'path': {'type': 'string'},
        }, ['path']),
        _tool(
          'read_note',
          'Baca isi catatan (path relatif vault, dibatasi ${SimpulBridge._maxReadChars} karakter)',
          {
            'path': {'type': 'string'},
          },
          ['path'],
        ),
        _tool('clusters', 'Deteksi komunitas Louvain atas graf tautan', {}, []),
        _tool('suggest_links', 'Saran tautan antar catatan serupa yang belum tertaut', {
          'limit': {'type': 'integer'},
          'min_score': {'type': 'number'},
        }, []),
      ];

  static Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) =>
      {
        'name': name,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      };

  static String _result(Object? id, Map<String, Object?> result) => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      });

  static String _error(Object? id, int code, String message) => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });
}
