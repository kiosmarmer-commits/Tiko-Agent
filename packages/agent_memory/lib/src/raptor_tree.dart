/// Fase 33 — RAPTOR-lite hierarchical summary tree (audit 2026-11-28 §6
/// #12, gap: "hierarchical summary tree tidak ditemukan"). "Adopt
/// selectively": BUKAN replikasi paper penuh (tanpa embedding-clusterer
/// GMM dan tanpa LLM summarizer default) — versi deterministik murni:
/// clustering greedy berbasis overlap token + ringkasan ekstraktif.
///
/// Tujuan: pertanyaan global lintas dokumen ("apa tema utama korpus?") bisa
/// dijawab dari simpul ringkasan level atas, lalu drill-down ke chunk
/// sumber untuk citation. Pipa retrieval utama (hybrid RAG) tidak berubah.
///
/// Batas keras: kedalaman ≤ 3, maks node per level, maks anak per node —
/// semua deterministik dan never-raises terhadap caller.

import 'dart:convert';
import 'dart:io';

/// Satu simpul pohon: ringkasan level [level], anak-anaknya, dan chunk
/// sumber yang dicakupnya (untuk citation drill-down).
class RaptorNode {
  RaptorNode({
    required this.id,
    required this.level,
    required this.summary,
    List<String> childIds = const [],
    List<String> sourceChunkIds = const [],
  })  : childIds = List.of(childIds),
        sourceChunkIds = List.of(sourceChunkIds);

  final String id;
  final int level;
  final String summary;
  final List<String> childIds;
  final List<String> sourceChunkIds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'level': level,
        'summary': summary,
        'children': childIds,
        'sources': sourceChunkIds,
      };

  static RaptorNode fromJson(Map<String, dynamic> json) => RaptorNode(
        id: json['id'] as String? ?? '',
        level: (json['level'] as num?)?.toInt() ?? 0,
        summary: json['summary'] as String? ?? '',
        childIds: (json['children'] as List<dynamic>? ?? const [])
            .cast<String>(),
        sourceChunkIds: (json['sources'] as List<dynamic>? ?? const [])
            .cast<String>(),
      );
}

/// Hasil query pohon: simpul yang match (urut skor) + chunk sumbernya.
class RaptorQueryResult {
  const RaptorQueryResult({
    required this.matchedNodes,
    required this.sourceChunkIds,
  });

  final List<(RaptorNode, double)> matchedNodes;
  final List<String> sourceChunkIds;
}

/// Pohon ringkasan RAPTOR-lite. Build sekali per indeks; disimpan sebagai
/// JSON agar pasca-restart tidak perlu rebuild (build sendiri bersifat
/// deterministik — hasil build ulang identik).
class RaptorTree {
  RaptorTree({
    this.maxDepth = 3,
    this.maxChildren = 4,
    this.maxNodesPerLevel = 32,
    this.clusterMinOverlap = 0.15,
    this.maxSummaryChars = 400,
  })  : assert(maxDepth >= 1 && maxDepth <= 4),
        assert(maxChildren >= 2),
        assert(maxNodesPerLevel >= 2);

  final int maxDepth;
  final int maxChildren;
  final int maxNodesPerLevel;
  final double clusterMinOverlap;
  final int maxSummaryChars;

  final Map<String, RaptorNode> _nodes = {};
  bool _built = false;

  bool get built => _built;
  int get nodeCount => _nodes.length;
  Iterable<RaptorNode> get nodes => _nodes.values;

  RaptorNode? getNode(String id) => _nodes[id];

  /// Bangun pohon dari daftar chunk (level 0). Deterministik: chunk diurut
  /// per (docId, index) dulu. Return jumlah total node termasuk daun.
  int build(List<({String id, String text})> leaves) {
    _nodes.clear();
    var level = 0;
    var current = [
      for (final leaf in leaves.where((l) => l.text.trim().isNotEmpty))
        RaptorNode(
          id: leaf.id.startsWith('L0:') ? leaf.id : 'L0:${leaf.id}',
          level: 0,
          summary: _truncate(leaf.text),
          sourceChunkIds: [leaf.id],
        ),
    ];
    // Dedup id.
    final seen = <String>{};
    current = [for (final n in current) if (seen.add(n.id)) n];
    for (final n in current) {
      _nodes[n.id] = n;
    }
    while (current.length > 1 && level < maxDepth - 1) {
      final clusters = _cluster(current);
      final next = <RaptorNode>[];
      var i = 0;
      for (final cluster in clusters) {
        if (cluster.length < 2) continue;
        final id = 'L${level + 1}:$i';
        i++;
        final node = RaptorNode(
          id: id,
          level: level + 1,
          summary: _summarize(
            [for (final c in cluster) c.summary],
          ),
          childIds: [for (final c in cluster) c.id],
          sourceChunkIds: [
            for (final c in cluster) ...c.sourceChunkIds,
          ],
        );
        _nodes[id] = node;
        next.add(node);
      }
      if (next.isEmpty || next.length >= current.length) break;
      current = next.length > maxNodesPerLevel
          ? next.sublist(0, maxNodesPerLevel)
          : next;
      level++;
    }
    _built = _nodes.isNotEmpty;
    return _nodes.length;
  }

  /// Query lexical-skor query terhadap ringkasan tiap node (level atas
  /// lebih diutamakan untuk pertanyaan global). Return simpul match + semua
  /// chunk sumber di bawahnya (dedup, terbatas [maxSourceChunks]).
  RaptorQueryResult query(
    String queryString, {
    int topK = 4,
    int maxSourceChunks = 24,
  }) {
    final terms = _terms(queryString);
    if (terms.isEmpty || !_built) {
      return const RaptorQueryResult(
        matchedNodes: [],
        sourceChunkIds: [],
      );
    }
    final scored = <(RaptorNode, double)>[];
    for (final node in _nodes.values) {
      final nodeTerms = _terms(node.summary);
      if (nodeTerms.isEmpty) continue;
      var overlap = 0;
      for (final t in terms) {
        if (nodeTerms.contains(t)) overlap++;
      }
      final score = overlap / terms.length;
      // Level atas diberi bonus kecil: pertanyaan global dijawab ringkasan.
      final adjusted =
          score + (node.level > 0 ? 0.05 * node.level : 0.0);
      if (score > 0) scored.add((node, adjusted));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      return a.$1.id.compareTo(b.$1.id);
    });
    final top = scored.take(topK).toList();
    final sources = <String>{};
    for (final (node, _) in top) {
      for (final s in node.sourceChunkIds) {
        if (sources.length >= maxSourceChunks) break;
        sources.add(s);
      }
    }
    return RaptorQueryResult(
      matchedNodes: top,
      sourceChunkIds: sources.toList(),
    );
  }

  /// Clustering greedy deterministik: urut node per id; tiap node masuk ke
  /// cluster dengan overlap token tertinggi (≥ ambang), kalau tidak ada
  /// buat cluster baru; cluster terakhir digabung bila melebihi cap.
  List<List<RaptorNode>> _cluster(List<RaptorNode> nodes) {
    final clusters = <List<RaptorNode>>[];
    final termCache = <String, Set<String>>{
      for (final n in nodes) n.id: _terms(n.summary),
    };
    for (final node in [
      ...nodes,
    ]..sort((a, b) => a.id.compareTo(b.id))) {
      final terms = termCache[node.id]!;
      if (terms.isEmpty) {
        clusters.add([node]);
        continue;
      }
      var bestIndex = -1;
      var bestOverlap = 0.0;
      for (var i = 0; i < clusters.length; i++) {
        final clusterTerms = <String>{
          for (final m in clusters[i]) ...termCache[m.id]!,
        };
        if (clusterTerms.isEmpty) continue;
        var overlap = 0;
        for (final t in terms) {
          if (clusterTerms.contains(t)) overlap++;
        }
        final ratio = overlap / terms.length;
        if (ratio >= clusterMinOverlap && ratio > bestOverlap) {
          bestOverlap = ratio;
          bestIndex = i;
        }
      }
      if (bestIndex >= 0 && clusters[bestIndex].length < maxChildren) {
        clusters[bestIndex].add(node);
      } else {
        clusters.add([node]);
      }
    }
    // Cap jumlah cluster per level (gabung terkecil ke tetangganya).
    while (clusters.length > maxNodesPerLevel) {
      clusters[maxNodesPerLevel - 1].addAll(clusters.removeLast());
    }
    return clusters;
  }

  /// Ringkasan ekstraktif deterministik: kalimat-kalimat yang memuat term
  /// paling sering, dipertahankan urutan asli, dibatasi [maxSummaryChars].
  String _summarize(List<String> texts) {
    final freq = <String, int>{};
    final allTerms = <Set<String>>[];
    for (final t in texts) {
      final terms = _terms(t);
      allTerms.add(terms);
      for (final term in terms) {
        freq[term] = (freq[term] ?? 0) + 1;
      }
    }
    final topTerms =
        (freq.keys.toList()..sort((a, b) => (freq[b] ?? 0).compareTo(freq[a] ?? 0)))
            .take(8)
            .toSet();
    final kept = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      final sentences = texts[i]
          .split(RegExp(r'(?<=[.!?])\s+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      for (final s in sentences) {
        final st = _terms(s);
        final hits = st.intersection(topTerms).length;
        if (hits >= 2 || (hits >= 1 && st.length <= 6)) {
          final piece = s.trim();
          if (buffer.length + piece.length + 1 > maxSummaryChars) continue;
          if (kept.contains(piece)) continue;
          kept.add(piece);
          buffer.write(buffer.isEmpty ? piece : ' $piece');
        }
      }
    }
    final out = buffer.toString().trim();
    return out.isEmpty
        ? _truncate(texts.join(' '))
        : out;
  }

  static Set<String> _terms(String text) {
    final raw = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u00c0-\u024f]+'))
        .where((t) => t.length >= 3);
    const stopwords = {
      'dan', 'yang', 'dari', 'untuk', 'dengan', 'pada', 'adalah', 'itu',
      'the', 'and', 'for', 'with', 'this', 'that', 'are', 'was', 'has',
      'have', 'not', 'but', 'you', 'your', 'dapat', 'akan', 'juga', 'bila',
    };
    return {
      for (final t in raw)
        if (!stopwords.contains(t)) t,
    };
  }

  String _truncate(String text) => text.length <= maxSummaryChars
      ? text.trim()
      : '${text.substring(0, maxSummaryChars).trim()}…';

  Map<String, dynamic> toJson() => {
        'max_depth': maxDepth,
        'max_children': maxChildren,
        'max_nodes_per_level': maxNodesPerLevel,
        'nodes': [for (final n in _nodes.values) n.toJson()],
      };

  static RaptorTree fromJson(Map<String, dynamic> json) {
    final tree = RaptorTree(
      maxDepth: (json['max_depth'] as num?)?.toInt() ?? 3,
      maxChildren: (json['max_children'] as num?)?.toInt() ?? 4,
      maxNodesPerLevel:
          (json['max_nodes_per_level'] as num?)?.toInt() ?? 32,
    );
    for (final n in json['nodes'] as List<dynamic>? ?? const []) {
      if (n is Map<String, dynamic>) {
        final node = RaptorNode.fromJson(n);
        if (node.id.isNotEmpty) tree._nodes[node.id] = node;
      }
    }
    tree._built = tree._nodes.isNotEmpty;
    return tree;
  }

  /// Simpan pohon ke [path] (buat direktori bila perlu); false bila gagal.
  bool save(String path) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  static RaptorTree? load(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
