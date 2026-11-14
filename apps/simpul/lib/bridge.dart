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
  SimpulBridge({required this.vaultDir, this.token, AiAccessPolicy Function()? policyLoader})
      : policyLoader = policyLoader ?? (() => AiAccessPolicy.load(vaultDir));

  final String vaultDir;
  final String? token;

  /// Reloaded on every tool call so permission changes take effect
  /// immediately (DIF-04); a corrupt config fails closed to deny-all.
  final AiAccessPolicy Function() policyLoader;

  static const _maxReadChars = 20000;

  VaultIndex? _index;

  AiAccessPolicy _policy() {
    try {
      return policyLoader();
    } catch (_) {
      return AiAccessPolicy.denyAll();
    }
  }

  /// Effective decision for a set of paths; tag rules need the notes' tags,
  /// fetched from the index only when tag rules exist.
  Future<AiAccessDecision> _decide(
    AiAccessPolicy policy,
    VaultIndex index,
    String path,
  ) async {
    var tags = const <String>{};
    if (policy.tags.isNotEmpty) {
      tags = (await index.tagsOf({path}))[path]?.toSet() ?? const {};
    }
    return policy.decide(path, tags: tags);
  }

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
    final policy = _policy();
    final audit = AiAuditLogger(vaultDir);
    final target = (args['query'] ?? args['path'] ?? '-').toString();
    try {
      final data = await switch (name) {
        'search' => _search(args, policy, audit),
        'semsearch' => _semsearch(args, policy, audit),
        'ask_vault' => _askVault(args, policy, audit),
        'health' => _health(),
        'backlinks' => _backlinks(args, policy),
        'read_note' => _readNote(args, policy),
        'clusters' => _clusters(policy),
        'suggest_links' => _suggestLinks(args, policy),
        _ => throw ArgumentError('tool tidak dikenal: $name'),
      };
      audit.log(tool: name, target: target, decision: AiAccessDecision.allow);
      return _result(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(data)},
        ],
      });
    } on AiAccessDenied catch (e) {
      audit.log(
        tool: name,
        target: target,
        decision: e.decision,
        detail: {'reason': e.message},
      );
      return _result(id, {
        'content': [
          {'type': 'text', 'text': e.message},
        ],
        'isError': true,
      });
    } on ArgumentError catch (e) {
      audit.log(
        tool: name,
        target: target,
        decision: AiAccessDecision.allow,
        detail: {'status': 'argument_error'},
      );
      return _result(id, {
        'content': [
          {'type': 'text', 'text': '${e.message}'},
        ],
        'isError': true,
      });
    } catch (e) {
      audit.log(
        tool: name,
        target: target,
        decision: AiAccessDecision.allow,
        detail: {'status': 'error'},
      );
      return _result(id, {
        'content': [
          {'type': 'text', 'text': 'gagal: $e'},
        ],
        'isError': true,
      });
    }
  }

  /// "Tanya vault" (AI-21/22/23) over the bridge: retrieval is fused from
  /// lexical + vector hits, then a second pass re-asks restricted to
  /// policy-allowed paths so no denied content can leak into the answer
  /// (headless = extractive mode; an LLM would need human-in-the-loop).
  Future<Object?> _askVault(
    Map<String, Object?> args,
    AiAccessPolicy policy,
    AiAuditLogger audit,
  ) async {
    final query = args['query'];
    if (query is! String || query.isEmpty) {
      throw ArgumentError('query wajib string non-kosong');
    }
    final index = await _openIndex();
    final vectorsFile = File(p.join(vaultDir, '.simpul', 'vectors.json'));
    final semantic = vectorsFile.existsSync()
        ? InMemorySemanticIndex(
            HashingEmbedder(),
            filePath: vectorsFile.path,
            crypto: await _vaultCrypto(),
          )
        : null;
    try {
      final answerer = VaultAnswerer(
        index: index,
        semantic: semantic,
        embedder: HashingEmbedder(),
      );
      final limit = _intArg(args, 'limit', 8);
      final first = await answerer.ask(query, limit: limit);
      final allowed = <String>{};
      var denied = 0;
      for (final chunk in first.citations) {
        if (await _decide(policy, index, chunk.path) == AiAccessDecision.allow) {
          allowed.add(chunk.path);
        } else {
          denied++;
        }
      }
      final RagAnswer answer;
      if (denied == 0) {
        answer = first;
      } else if (allowed.isEmpty) {
        answer = const RagAnswer(
          mode: 'not_found',
          answer: 'Tidak ada bukti yang diizinkan untuk pertanyaan ini.',
          citations: [],
        );
      } else {
        answer = await answerer.ask(query, limit: limit, allowedPaths: allowed);
      }
      if (denied > 0) {
        audit.log(
          tool: 'ask_vault',
          target: query,
          decision: AiAccessDecision.allow,
          detail: {'filtered': denied},
        );
      }
      return {
        'query': query,
        ...answer.toJson(),
        if (denied > 0) 'filtered': denied,
      };
    } finally {
      await semantic?.close();
    }
  }

  Future<VaultCrypto?> _vaultCrypto() async {
    final modeFile = File(p.join(vaultDir, '.simpul', 'vault-mode.json'));
    if (!modeFile.existsSync()) return null;
    final password = Platform.environment['SIMPUL_PASSWORD'];
    if (password == null || password.isEmpty) {
      throw ArgumentError(
        'vault terkunci — set SIMPUL_PASSWORD sebelum menjalankan bridge',
      );
    }
    final crateFile = File(p.join(vaultDir, '.simpul', 'vault-key.crate'));
    if (!crateFile.existsSync()) {
      throw StateError('crate kunci vault tidak ditemukan: ${crateFile.path}');
    }
    return VaultCrypto.open(crateFile.readAsBytesSync(), password: password);
  }

  Future<VaultIndex> _openIndex() async {
    final existing = _index;
    if (existing != null) return existing;
    final dir = p.join(vaultDir, '.simpul');
    final dbFile = File(p.join(dir, 'index.db'));
    final jsonFile = File(p.join(dir, 'index.json'));
    final crypto = await _vaultCrypto();
    if (dbFile.existsSync()) {
      if (crypto != null) {
        throw StateError(
          'backend sqlite belum didukung pada vault terenkripsi '
          '(SQLCipher belum tersedia) — pakai backend JSON',
        );
      }
      final sqlite = SqliteVaultIndex.tryOpen(dbFile.path);
      if (sqlite != null) {
        _index = sqlite;
        return sqlite;
      }
    }
    if (jsonFile.existsSync()) {
      final json = JsonVaultIndex(jsonFile.path, crypto: crypto);
      _index = json;
      return json;
    }
    throw ArgumentError('indeks belum ada — jalankan: simpul index "$vaultDir"');
  }

  Future<Object?> _search(
    Map<String, Object?> args,
    AiAccessPolicy policy,
    AiAuditLogger audit,
  ) async {
    final query = args['query'];
    if (query is! String || query.isEmpty) {
      throw ArgumentError('query wajib string non-kosong');
    }
    final index = await _openIndex();
    final hits = await index.search(query, limit: _intArg(args, 'limit', 20));
    final allowed = <SearchHit>[];
    for (final h in hits) {
      if (await _decide(policy, index, h.path) == AiAccessDecision.allow) {
        allowed.add(h);
      }
    }
    if (allowed.length < hits.length) {
      audit.log(
        tool: 'search',
        target: query,
        decision: AiAccessDecision.allow,
        detail: {'filtered': hits.length - allowed.length},
      );
    }
    return {
      'query': query,
      if (allowed.length < hits.length) 'filtered': hits.length - allowed.length,
      'hits': [
        for (final h in allowed)
          {'path': h.path, 'score': h.score, 'snippet': h.snippet},
      ],
    };
  }

  Future<Object?> _semsearch(
    Map<String, Object?> args,
    AiAccessPolicy policy,
    AiAuditLogger audit,
  ) async {
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
      crypto: await _vaultCrypto(),
    );
    try {
      final hits = await semantic.search(
        embedder.embed(query),
        limit: _intArg(args, 'limit', 20),
      );
      final index = await _openIndex();
      final allowed = <SemanticHit>[];
      for (final h in hits) {
        if (await _decide(policy, index, h.notePath) == AiAccessDecision.allow) {
          allowed.add(h);
        }
      }
      if (allowed.length < hits.length) {
        audit.log(
          tool: 'semsearch',
          target: query,
          decision: AiAccessDecision.allow,
          detail: {'filtered': hits.length - allowed.length},
        );
      }
      return {
        'query': query,
        'model': embedder.modelVersion,
        if (allowed.length < hits.length) 'filtered': hits.length - allowed.length,
        'hits': [
          for (final h in allowed)
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

  Future<Object?> _backlinks(Map<String, Object?> args, AiAccessPolicy policy) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw ArgumentError('path wajib string non-kosong');
    }
    final index = await _openIndex();
    final sources = <String>[];
    for (final source in await index.backlinks(path)) {
      if (await _decide(policy, index, source) == AiAccessDecision.allow) {
        sources.add(source);
      }
    }
    return {'path': path, 'backlinks': sources};
  }

  Future<Object?> _readNote(Map<String, Object?> args, AiAccessPolicy policy) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw ArgumentError('path wajib string non-kosong');
    }
    final index = await _openIndex();
    final decision = await _decide(policy, index, path);
    if (decision != AiAccessDecision.allow) {
      throw AiAccessDenied(decision, path);
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

  Future<Object?> _clusters(AiAccessPolicy policy) async {
    final notes = await VaultScanner.scan(vaultDir);
    final allowed = [
      for (final note in notes)
        if (policy.decide(note.path, tags: note.parsed.tags.toSet()) ==
            AiAccessDecision.allow)
          note,
    ];
    final graph = GraphCsr.build(allowed.map((n) => n.toIndexed()).toList());
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

  Future<Object?> _suggestLinks(Map<String, Object?> args, AiAccessPolicy policy) async {
    final notes = await VaultScanner.scan(vaultDir);
    final allowed = [
      for (final note in notes)
        if (policy.decide(note.path, tags: note.parsed.tags.toSet()) ==
            AiAccessDecision.allow)
          note,
    ];
    final suggestions = await LinkSuggester.suggest(
      allowed.map((n) => n.toIndexed()).toList(),
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
        _tool(
          'ask_vault',
          'Tanya vault (RAG, AI-21): jawaban ekstraktif ber-sitasi [n] ke '
              'catatan + heading dari bukti yang diizinkan; bukti kurang → '
              '"tidak ditemukan" (AI-22)',
          {
            'query': {'type': 'string'},
            'limit': {'type': 'integer'},
            'budget': {'type': 'integer'},
          },
          ['query'],
        ),
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
