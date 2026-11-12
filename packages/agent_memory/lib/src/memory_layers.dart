import 'dart:convert';
import 'dart:math' as math;

import 'dart:io';

/// Advanced memory system: layered memory with importance scoring,
/// Ebbinghaus-style decay, and episodic → semantic consolidation.
///
/// Layers mirror cognitive memory models, matching the Hermes memory
/// design:
/// - `episodic`: raw events of a session ("user asked X, agent did Y").
/// - `semantic`: distilled facts and preferences ("user prefers Bahasa").
/// - `procedural`: how-to knowledge ("to deploy, run scripts/apply.sh").
///
/// All scoring is deterministic; time is injected so tests can freeze it.

enum MemoryLayerType { episodic, semantic, procedural }

/// One memory entry stored in a [LayeredMemory].
class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.layer,
    required this.text,
    required this.createdAt,
    this.importance = 0.5,
    this.accessCount = 0,
    DateTime? lastAccessedAt,
    this.tags = const [],
    this.ownerKey,
    this.sourceSession,
    this.consolidated = false,
  }) : lastAccessedAt = lastAccessedAt ?? createdAt;

  final String id;
  final MemoryLayerType layer;
  final String text;
  final DateTime createdAt;

  /// Base importance 0..1, set at write time (user emphasis, feedback).
  final double importance;
  int accessCount;
  DateTime lastAccessedAt;
  final List<String> tags;
  final String? ownerKey;
  final String? sourceSession;

  /// True when this entry has already been distilled into the semantic
  /// layer (episodic entries only).
  bool consolidated;

  /// Retention factor 0..1 following exponential decay:
  /// `0.5 ^ (ageDays / halfLifeDays)`. Never reaches zero; forgetting is
  /// applied against [LayeredMemory.decayFloor].
  double retention(DateTime now, {required double halfLifeDays}) {
    final ageDays =
        now.toUtc().difference(createdAt.toUtc()).inMilliseconds /
            Duration.millisecondsPerDay;
    if (ageDays <= 0) return 1.0;
    return math.pow(0.5, ageDays / halfLifeDays).toDouble();
  }

  /// Effective importance = base importance × retention × access boost.
  double effectiveScore(DateTime now, {required double halfLifeDays}) {
    final boost = 1.0 + math.min(accessCount, 10) * 0.05;
    return (importance * retention(now, halfLifeDays: halfLifeDays) * boost)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'layer': layer.name,
        'text': text,
        'importance': importance,
        'access_count': accessCount,
        'created_at': createdAt.toUtc().toIso8601String(),
        'last_accessed_at': lastAccessedAt.toUtc().toIso8601String(),
        'tags': tags,
        if (ownerKey != null) 'owner_key': ownerKey,
        if (sourceSession != null) 'source_session': sourceSession,
        'consolidated': consolidated,
      };

  factory MemoryEntry.fromJson(Map<String, dynamic> json) {
    final layerName = json['layer'] as String? ?? 'episodic';
    return MemoryEntry(
      id: json['id'] as String? ?? '',
      layer: MemoryLayerType.values.firstWhere(
        (l) => l.name == layerName,
        orElse: () => MemoryLayerType.episodic,
      ),
      text: json['text'] as String? ?? '',
      importance:
          (json['importance'] as num?)?.toDouble() ?? 0.5,
      accessCount: json['access_count'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')
              ?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastAccessedAt:
          DateTime.tryParse(json['last_accessed_at'] as String? ?? '')
                  ?.toUtc() ??
              null,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString())
          .toList() ?? const [],
      ownerKey: json['owner_key'] as String?,
      sourceSession: json['source_session'] as String?,
      consolidated: json['consolidated'] as bool? ?? false,
    );
  }
}

/// Outcome of one consolidation pass.
class ConsolidationReport {
  ConsolidationReport({
    this.promoted = 0,
    this.decayed = 0,
    this.forgotten = 0,
  });

  /// Episodic entries distilled into new semantic entries.
  int promoted;

  /// Entries whose effective score dropped below the promotion bar but
  /// survived forgetting.
  int decayed;

  /// Entries removed because their effective score fell under the floor.
  int forgotten;

  Map<String, dynamic> toJson() => {
        'promoted': promoted,
        'decayed': decayed,
        'forgotten': forgotten,
      };
}

/// In-memory layered memory with optional JSON persistence.
class LayeredMemory {
  LayeredMemory({
    this.halfLifeDays = 14,
    this.decayFloor = 0.05,
    this.promotionAccessThreshold = 3,
    this.promotionImportance = 0.6,
  }) {
    if (halfLifeDays <= 0) {
      throw ArgumentError('halfLifeDays must be > 0');
    }
  }

  final double halfLifeDays;
  final double decayFloor;

  /// An episodic entry accessed at least this many times is a candidate
  /// for consolidation into the semantic layer.
  final int promotionAccessThreshold;

  /// Consolidation candidates must also hold at least this importance.
  final double promotionImportance;

  final Map<String, MemoryEntry> _entries = {};
  int _seq = 0;

  int get length => _entries.length;

  Iterable<MemoryEntry> get all => _entries.values;

  int countLayer(MemoryLayerType layer) =>
      _entries.values.where((e) => e.layer == layer).length;

  MemoryEntry? get(String id) => _entries[id];

  /// Adds an entry and returns it. Ids are auto-generated when omitted.
  MemoryEntry add(
    MemoryLayerType layer,
    String text, {
    double importance = 0.5,
    List<String> tags = const [],
    String? ownerKey,
    String? sourceSession,
    DateTime? now,
    String? id,
  }) {
    if (text.trim().isEmpty) {
      throw ArgumentError('memory text must not be empty');
    }
    final entry = MemoryEntry(
      id: id ?? 'm${_seq++}',
      layer: layer,
      text: text.trim(),
      importance: importance.clamp(0.0, 1.0).toDouble(),
      createdAt: (now ?? DateTime.now()).toUtc(),
      tags: List<String>.from(tags),
      ownerKey: ownerKey,
      sourceSession: sourceSession,
    );
    _entries[entry.id] = entry;
    return entry;
  }

  /// Records an access, boosting future retrieval scores.
  void touch(String id, {DateTime? now}) {
    final entry = _entries[id];
    if (entry == null) return;
    entry
      ..accessCount = entry.accessCount + 1
      ..lastAccessedAt = (now ?? DateTime.now()).toUtc();
  }

  /// Removes an entry; returns true when it existed.
  bool remove(String id) => _entries.remove(id) != null;

  /// Cross-layer retrieval. Score = lexical overlap × effective score,
  /// optionally restricted to [layers] and scoped to [ownerKey]. Ties keep
  /// insertion order for determinism.
  List<MemoryEntry> retrieve(
    String query, {
    int k = 8,
    Set<MemoryLayerType>? layers,
    String? ownerKey,
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now()).toUtc();
    final queryTokens = _tokens(query);
    final scored = <(double, int, MemoryEntry)>[];
    var index = 0;
    for (final entry in _entries.values) {
      if (layers != null && !layers.contains(entry.layer)) continue;
      if (ownerKey != null && entry.ownerKey != null &&
          entry.ownerKey != ownerKey) {
        continue;
      }
      final overlap = _overlap(queryTokens, entry.text);
      final score = overlap * entry.effectiveScore(at, halfLifeDays: halfLifeDays);
      scored.add((score, index++, entry));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      if (byScore != 0) return byScore;
      return a.$2.compareTo(b.$2);
    });
    return [
      for (final s in scored.take(k)) s.$3,
    ];
  }

  /// Consolidation pass:
  /// 1. Promotes strong episodic entries (frequently accessed + important)
  ///    into distilled semantic entries and marks the originals.
  /// 2. Counts decayed entries (below the promotion bar, above the floor).
  /// 3. Forgets entries whose effective score fell under [decayFloor].
  ConsolidationReport consolidate({DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final report = ConsolidationReport();
    final toPromote = <MemoryEntry>[];
    for (final entry in _entries.values) {
      if (entry.layer != MemoryLayerType.episodic || entry.consolidated) {
        continue;
      }
      if (entry.accessCount >= promotionAccessThreshold &&
          entry.importance >= promotionImportance) {
        toPromote.add(entry);
      }
    }
    for (final entry in toPromote) {
      final semantic = MemoryEntry(
        id: '${entry.id}:semantic',
        layer: MemoryLayerType.semantic,
        text: entry.text,
        importance: math.min(1.0, entry.importance + 0.1),
        createdAt: at,
        tags: entry.tags,
        ownerKey: entry.ownerKey,
        sourceSession: entry.sourceSession,
      );
      _entries[semantic.id] = semantic;
      entry
        ..consolidated = true
        ..accessCount = 0;
      report.promoted++;
    }
    final doomed = <String>[];
    for (final entry in _entries.values) {
      final score = entry.effectiveScore(at, halfLifeDays: halfLifeDays);
      if (score < decayFloor) {
        doomed.add(entry.id);
      } else if (score < promotionImportance) {
        report.decayed++;
      }
    }
    for (final id in doomed) {
      _entries.remove(id);
      report.forgotten++;
    }
    return report;
  }

  /// Per-layer entry counts and average effective scores.
  Map<String, dynamic> stats({DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final out = <String, dynamic>{};
    for (final layer in MemoryLayerType.values) {
      final entries =
          _entries.values.where((e) => e.layer == layer).toList();
      final avg = entries.isEmpty
          ? 0.0
          : entries
                  .map((e) => e.effectiveScore(at, halfLifeDays: halfLifeDays))
                  .reduce((a, b) => a + b) /
              entries.length;
      out[layer.name] = {'count': entries.length, 'avg_score': avg};
    }
    return out;
  }

  /// Persists all entries as JSON at [path].
  Future<void> save(String path) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'seq': _seq,
      'entries': [for (final e in _entries.values) e.toJson()],
    }));
  }

  /// Loads entries previously written by [save]. Corrupt files are ignored
  /// so a damaged store degrades to empty instead of crashing the agent.
  Future<void> load(String path) async {
    final f = File(path);
    if (!await f.exists()) return;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _seq = json['seq'] as int? ?? 0;
      for (final raw in json['entries'] as List<dynamic>? ?? []) {
        if (raw is! Map<String, dynamic>) continue;
        final entry = MemoryEntry.fromJson(raw);
        _entries[entry.id] = entry;
      }
    } catch (_) {}
  }

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  static double _overlap(Set<String> queryTokens, String text) {
    if (queryTokens.isEmpty) return 0;
    final textTokens = _tokens(text);
    if (textTokens.isEmpty) return 0;
    return queryTokens.where((t) => textTokens.contains(t)).length /
        queryTokens.length;
  }
}
