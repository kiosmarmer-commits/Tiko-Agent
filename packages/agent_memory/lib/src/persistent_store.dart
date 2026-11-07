import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'fts_index.dart';

/// Disk-backed MemoryStore (AGD-04). Messages + facts as JSON files.
class PersistentMemoryStore implements MemoryStore, OwnerScopedMemoryStore {
  PersistentMemoryStore({
    required this.dataDir,
    this.vectorIndex,
    this.embedder,
    this.maxFacts = 5000,
  }) {
    Directory(dataDir).createSync(recursive: true);
    Directory(p.join(dataDir, 'messages')).createSync(recursive: true);
    fts = FtsIndex(p.join(dataDir, 'fts.json'));
    _ready = _initialize();
  }

  late final FtsIndex fts;
  late final Future<void> _ready;

  Future<void> _initialize() async {
    await fts.load();
    _loadFacts();
  }

  final String dataDir;
  final VectorIndex? vectorIndex;
  final Future<List<double>> Function(String text)? embedder;
  final int maxFacts;
  final _uuid = const Uuid();

  final Map<String, Fact> facts = {};
  final Map<String, List<Message>> _msgCache = {};

  String get _factsPath => p.join(dataDir, 'facts.json');

  void _loadFacts() {
    final f = File(_factsPath);
    if (!f.existsSync()) return;
    try {
      if (f.lengthSync() > 8 * 1024 * 1024) {
        throw const FormatException('memory facts file exceeds 8 MiB');
      }
      final list = jsonDecode(f.readAsStringSync()) as List<dynamic>;
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        final fact = Fact(
          id: m['id'] as String,
          text: m['text'] as String,
          kind: m['kind'] as String? ?? 'fact',
          importance: (m['importance'] as num?)?.toDouble() ?? 0.5,
          sourceSession: m['source_session'] as String?,
          ownerKey: m['owner_key'] as String?,
          createdAt: DateTime.tryParse(m['created_at'] as String? ?? '')?.toUtc() ??
              ((m['ttl_days'] as int?) != null ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true) : null),
          provenance: Fact.provenanceFromName(m['provenance']),
          confidence: (m['confidence'] as num?)?.toDouble() ?? 0.7,
          ttlDays: m['ttl_days'] as int?,
          state: m['state'] as String? ?? 'active',
        );
        facts[fact.id] = fact;
        fts.upsert(fact.id, fact.text);
      }
    } catch (_) {
      final corrupt = File('$_factsPath.corrupt');
      try {
        if (corrupt.existsSync()) corrupt.deleteSync();
        f.renameSync(corrupt.path);
      } catch (_) {
        // Preserve the original file if quarantine cannot be completed.
      }
    }
  }

  Future<void> _saveFacts() async {
    final list = facts.values
        .map(
          (f) => {
            'id': f.id,
            'text': f.text,
            'kind': f.kind,
            'importance': f.importance,
            'source_session': f.sourceSession,
            'owner_key': f.ownerKey,
            'created_at': f.createdAt?.toUtc().toIso8601String(),
            'provenance': f.provenance.name,
            'confidence': f.confidence,
            'ttl_days': f.ttlDays,
            'state': f.state,
          },
        )
        .toList();
    final target = File(_factsPath);
    final temp = File('$_factsPath.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(list),
      flush: true,
    );
    try {
      await temp.rename(target.path);
    } on FileSystemException {
      final backup = File('$_factsPath.bak');
      var movedOld = false;
      try {
        if (await target.exists()) {
          if (await backup.exists()) await backup.delete();
          await target.rename(backup.path);
          movedOld = true;
        }
        await temp.rename(target.path);
        if (movedOld && await backup.exists()) await backup.delete();
      } catch (_) {
        if (movedOld && !await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
    }
  }

  String _msgPath(String sessionId) {
    final safe = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return p.join(dataDir, 'messages', '$safe.jsonl');
  }

  @override
  Future<void> addMessage(Message m) async {
    await _ready;
    final list = _msgCache.putIfAbsent(m.sessionId, () => []);
    list.add(m);
    final file = File(_msgPath(m.sessionId));
    await file.writeAsString(
      '${jsonEncode({'session_id': m.sessionId, 'role': m.role, 'content': m.content, 'tool_name': m.toolName, 'created_at': m.createdAt.toUtc().toIso8601String()})}\n',
      mode: FileMode.append,
    );
  }

  Future<List<Message>> loadMessages(
    String sessionId, {
    int limit = 100,
  }) async {
    await _ready;
    if (_msgCache.containsKey(sessionId)) {
      final all = _msgCache[sessionId]!;
      return all.length <= limit
          ? List.from(all)
          : all.sublist(all.length - limit);
    }
    final file = File(_msgPath(sessionId));
    if (!await file.exists()) return [];
    final out = <Message>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        out.add(
          Message(
            sessionId: m['session_id'] as String? ?? sessionId,
            role: m['role'] as String? ?? 'user',
            content: m['content'] as String? ?? '',
            toolName: m['tool_name'] as String?,
          ),
        );
      } catch (_) {}
    }
    _msgCache[sessionId] = out;
    return out.length <= limit ? out : out.sublist(out.length - limit);
  }

  @override
  Future<void> upsertFact(Fact f) async {
    await _ready;
    if (f.text.length > 300) return;
    if (_looksSecret(f.text)) return;

    for (final existing in facts.values) {
      if (existing.ownerKey == f.ownerKey && _jaccard(existing.text, f.text) > 0.85) {
        facts[existing.id] = Fact(
          id: existing.id,
          text: f.text,
          kind: f.kind,
          importance: f.importance > existing.importance
              ? f.importance
              : existing.importance,
          sourceSession: f.sourceSession ?? existing.sourceSession,
          ownerKey: f.ownerKey ?? existing.ownerKey,
          createdAt: existing.createdAt ?? f.createdAt ?? DateTime.now().toUtc(),
          provenance: _mergeProvenance(existing.provenance, f.provenance),
          confidence: f.confidence < existing.confidence
              ? f.confidence
              : existing.confidence,
          ttlDays: f.ttlDays ?? existing.ttlDays,
          state: existing.state == 'active' && f.state == 'active'
              ? 'active'
              : 'pending',
        );
        fts.upsert(existing.id, f.text);
        await fts.save();
        await _saveFacts();
        await _maybeEmbed(existing.id, f.text);
        return;
      }
    }
    final id = f.id.isEmpty ? _uuid.v4() : f.id;
    facts[id] = Fact(
      id: id,
      text: f.text,
      kind: f.kind,
      importance: f.importance,
      sourceSession: f.sourceSession,
      ownerKey: f.ownerKey,
      createdAt: f.createdAt ?? DateTime.now().toUtc(),
      provenance: f.provenance,
      confidence: f.confidence,
      ttlDays: f.ttlDays,
      state: f.state,
    );
    if (facts.length > maxFacts) {
      final sorted = facts.values.toList()
        ..sort((a, b) => a.importance.compareTo(b.importance));
      final excess = facts.length - maxFacts;
      for (var i = 0; i < excess; i++) {
        facts.remove(sorted[i].id);
      }
    }
    fts.upsert(id, f.text);
    await fts.save();
    await _saveFacts();
    await _maybeEmbed(id, f.text);
  }

  Future<void> _maybeEmbed(String id, String text) async {
    if (vectorIndex == null || embedder == null) return;
    final v = await embedder!(text);
    if (v.isNotEmpty) await vectorIndex!.upsert(id, v, {'text': text, 'owner_key': facts[id]?.ownerKey});
  }

  @override
  Future<List<MemoryHit>> search(String query, {int k = 8}) async {
    return _search(query, k: k);
  }

  @override
  Future<List<MemoryHit>> searchForOwner(String query, {required String ownerKey, int k = 8}) async {
    if (ownerKey.trim().isEmpty) return const [];
    return _search(query, k: k, ownerKey: ownerKey);
  }

  Future<List<MemoryHit>> _search(String query, {required int k, String? ownerKey}) async {
    await _ready;
    final now = DateTime.now().toUtc();
    final qTokens = _tokens(query);
    final textHits = <MemoryHit>[];
    // FTS inverted index first
    for (final h in fts.search(query, k: facts.length)) {
      final fact = facts[h.id];
      if (fact != null &&
          (ownerKey == null || fact.ownerKey == ownerKey) &&
          !fact.isExpiredAt(now)) {
        textHits.add(_hit(fact, h.score * (0.5 + 0.5 * fact.importance)));
      }
    }
    // fallback scan if sparse
    if (textHits.length < k) {
      for (final f in facts.values) {
        if ((ownerKey != null && f.ownerKey != ownerKey) || f.isExpiredAt(now)) continue;
        if (textHits.any((h) => h.id == f.id)) continue;
        final score =
            _bm25ish(qTokens, _tokens(f.text)) * (0.5 + 0.5 * f.importance);
        if (score > 0) {
          textHits.add(_hit(f, score));
        }
      }
    }
    textHits.sort((a, b) => b.score.compareTo(a.score));

    if (vectorIndex != null && embedder != null && query.trim().isNotEmpty) {
      final emb = await embedder!(query);
      if (emb.isNotEmpty) {
        final vHits = await vectorIndex!.topK(emb, k);
        final scopedVectorHits = vHits.where((v) {
          final fact = facts[v.id];
          return fact != null &&
              (ownerKey == null || fact.ownerKey == ownerKey) &&
              !fact.isExpiredAt(now);
        }).toList();
        final vecAsMem = scopedVectorHits
            .map(
              (v) => MemoryHit(
                id: v.id,
                text: (v.meta['text'] as String?) ?? facts[v.id]?.text ?? v.id,
                score: v.score,
                provenance: facts[v.id]?.provenance ?? Provenance.unknown,
                confidence: facts[v.id]?.confidence ?? 0.5,
                state: facts[v.id]?.state ?? 'pending',
                ttlDays: facts[v.id]?.ttlDays,
                ownerKey: facts[v.id]?.ownerKey,
                createdAt: facts[v.id]?.createdAt,
              ),
            )
            .toList();
        return _rrf([textHits, vecAsMem], top: k);
      }
    }
    return textHits.take(k).toList();
  }

  @override
  Future<void> afterTurn(Session session) async {
    // Explicit user memory is captured in AgentLoop through the safety wrapper.
  }

  /// Delete a fact from the JSON store and its text index atomically enough
  /// to recover from a process interruption on the next load.
  Future<bool> deleteFact(String id) async {
    await _ready;
    if (facts.remove(id) == null) return false;
    fts.remove(id);
    await fts.save();
    await _saveFacts();
    return true;
  }

  List<MemoryHit> _rrf(
    List<List<MemoryHit>> rankings, {
    int k = 60,
    int top = 8,
  }) {
    final scores = <String, double>{};
    final texts = <String, String>{};
    for (final ranking in rankings) {
      for (var i = 0; i < ranking.length; i++) {
        final h = ranking[i];
        scores[h.id] = (scores[h.id] ?? 0) + 1.0 / (k + i + 1);
        texts[h.id] = h.text;
      }
    }
    final merged =
        scores.entries
            .map(
              (e) => MemoryHit(
                id: e.key,
                text: texts[e.key] ?? e.key,
                score: e.value,
                provenance: facts[e.key]?.provenance ?? Provenance.unknown,
                confidence: facts[e.key]?.confidence ?? 0.5,
                state: facts[e.key]?.state ?? 'pending',
                ttlDays: facts[e.key]?.ttlDays,
                ownerKey: facts[e.key]?.ownerKey,
                createdAt: facts[e.key]?.createdAt,
              ),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    return merged.take(top).toList();
  }


  MemoryHit _hit(Fact fact, double score) => MemoryHit(
        id: fact.id,
        text: fact.text,
        score: score,
        provenance: fact.provenance,
        confidence: fact.confidence,
        state: fact.state,
        ttlDays: fact.ttlDays,
        ownerKey: fact.ownerKey,
        createdAt: fact.createdAt,
      );

  Provenance _mergeProvenance(Provenance a, Provenance b) {
    // An explicit new user confirmation may rehabilitate a legacy record
    // whose origin was not captured. Unknown data must never be upgraded by
    // an agent, web page, MCP server, or other imported source.
    if (a == Provenance.unknown &&
        (b == Provenance.user || b == Provenance.trustedConfig)) return b;
    if (a == Provenance.unknown || b == Provenance.unknown) return Provenance.unknown;
    const order = <Provenance>[
      Provenance.web,
      Provenance.email,
      Provenance.mcp,
      Provenance.localFile,
      Provenance.agent,
      Provenance.memory,
      Provenance.user,
      Provenance.trustedConfig,
    ];
    for (final candidate in order) {
      if (a == candidate || b == candidate) return candidate;
    }
    return Provenance.unknown;
  }

  bool _looksSecret(String t) {
    final lower = t.toLowerCase();
    return lower.contains('api_key') ||
        lower.contains('password') ||
        lower.contains('secret') ||
        RegExp(r'sk-[a-zA-Z0-9]{20,}').hasMatch(t);
  }

  Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1)
      .toSet();

  double _jaccard(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    return ta.intersection(tb).length / ta.union(tb).length;
  }

  double _bm25ish(Set<String> q, Set<String> doc) {
    if (q.isEmpty || doc.isEmpty) return 0;
    return q.intersection(doc).length / q.length;
  }
}
