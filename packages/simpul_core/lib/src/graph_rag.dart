/// Fase 34 — GraphRAG-lite (audit 2026-11-28 §6 #13, gap: "perlu
/// integration/query pipeline ke main agent untuk disebut GraphRAG").
/// "Adopt selectively": BUKAN replikasi penuh paper (tanpa LLM entity
/// extraction) — versi deterministik atas aset simpul yang sudah ada:
///
/// - Graph entitas = graph wikilink antar note ([GraphCsr.build]).
/// - Community = Louvain deterministik ([CommunityDetector.louvain], GRA-L05).
/// - Community summary = ringkasan ekstraktif deterministik dari judul +
///   snippet anggota.
/// - *Local query*: seed = match lexical judul/konten, ekspansi BFS ≤
///   [maxHops] lewat tautan; *global query*: match term query terhadap
///   ringkasan community.
/// - Output: context block ber-marker `[n] source` + daftar path sumber
///   (citation untuk prompt agent utama). Teks note dianggap untrusted
///   evidence — pipeline ini tidak mengubah permission AI-42.
///
/// Never-raises terhadap caller; graph kosong menghasilkan jawaban kosong.
library;

import 'community.dart';
import 'graph_csr.dart';
import 'vault_index.dart';

/// Satu sumber terkutip dalam jawaban graph.
class GraphRagSource {
  const GraphRagSource({
    required this.path,
    required this.title,
    required this.score,
    this.hops = 0,
    this.community = -1,
  });

  final String path;
  final String title;
  final double score;

  /// Jarak graph dari seed terdekat (0 = seed langsung).
  final int hops;

  /// Community id simpul; -1 bila graph tidak tersedia.
  final int community;

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'score': double.parse(score.toStringAsFixed(4)),
        'hops': hops,
        if (community >= 0) 'community': community,
      };
}

/// Jawaban GraphRAG: context siap-suntik + sumber terkutip.
class GraphRagAnswer {
  const GraphRagAnswer({
    required this.sources,
    required this.context,
    required this.communityCount,
    this.globalQuery = false,
  });

  final List<GraphRagSource> sources;

  /// Blok konteks ber-marker `[n] source` (sama dengan pola RagResult).
  final String context;
  final int communityCount;
  final bool globalQuery;

  bool get isEmpty => sources.isEmpty;
}

/// Pipeline GraphRAG-lite. Build sekali dari snapshot notes; query statis
/// setelahnya (rebuild saat vault berubah — host memanggil [build] lagi).
class GraphRagIndex {
  GraphRagIndex({
    this.maxHops = 2,
    this.maxSources = 12,
    this.maxSnippetChars = 200,
    this.maxCommunitySummaries = 16,
  })  : assert(maxHops >= 1 && maxHops <= 4),
        assert(maxSources >= 1);

  final int maxHops;
  final int maxSources;
  final int maxSnippetChars;
  final int maxCommunitySummaries;

  final List<IndexedNote> _notes = [];
  final Map<String, int> _idByPath = {};
  final Map<String, Set<String>> _adjacency = {};
  GraphCsr? _graph;
  CommunityResult? _communities;
  final Map<int, String> _communitySummary = {};
  bool _built = false;

  bool get built => _built;
  int get noteCount => _notes.length;
  int get communityCount => _communities?.communityCount ?? 0;

  /// Bangun graph + community + ringkasan. Return jumlah community.
  int build(List<IndexedNote> notes) {
    _notes
      ..clear()
      ..addAll([
        for (final n in notes)
          if (n.path.isNotEmpty) n,
      ]..sort((a, b) => a.path.compareTo(b.path)));
    _idByPath
      ..clear()
      ..addEntries([for (var i = 0; i < _notes.length; i++) MapEntry(_notes[i].path, i)]);
    _graph = _notes.isEmpty ? null : GraphCsr.build(_notes);
    _adjacency.clear();
    if (_graph != null) {
      for (var i = 0; i < _graph!.nodeCount; i++) {
        final neighbors = <String>{};
        for (var j = _graph!.offsets[i]; j < _graph!.offsets[i + 1]; j++) {
          final path = _graph!.paths[_graph!.targets[j]];
          if (path.isNotEmpty) neighbors.add(path);
        }
        _adjacency[_notes[i].path] = neighbors;
      }
    }
    _communities =
        _graph == null || _graph!.nodeCount == 0
            ? null
            : CommunityDetector.louvain(_graph!);
    _communitySummary.clear();
    if (_communities != null && _communities!.communityCount > 0) {
      final members = <int, List<IndexedNote>>{};
      for (var i = 0; i < _notes.length; i++) {
        final c =
            i < _communities!.communityOf.length
                ? _communities!.communityOf[i]
                : -1;
        if (c < 0) continue;
        members.putIfAbsent(c, () => []).add(_notes[i]);
      }
      for (final entry in members.entries) {
        _communitySummary[entry.key] = _summarizeCommunity(entry.value);
      }
    }
    _built = _notes.isNotEmpty;
    return _communities?.communityCount ?? 0;
  }

  /// Query gabungan: lokal (seed + hop) dan global (community summary).
  /// Return gabungan sumber terbaik (dedup per path, skor tertinggi menang).
  GraphRagAnswer query(String queryString, {int topK = 6}) {
    if (queryString.trim().isEmpty || !_built) {
      return GraphRagAnswer(
        sources: const [],
        context: '',
        communityCount: communityCount,
      );
    }
    final terms = _terms(queryString);
    if (terms.isEmpty) {
      return GraphRagAnswer(
        sources: const [],
        context: '',
        communityCount: communityCount,
      );
    }

    // Global: community summaries yang match term query.
    final globalScores = <int, double>{};
    _communitySummary.forEach((id, summary) {
      final s = _score(terms, summary);
      if (s > 0) globalScores[id] = s * 0.9;
    });
    final globalMembers = <int, List<int>>{};
    if (_communities != null) {
      for (var i = 0; i < _notes.length; i++) {
        final c = _communities!.communityOf[i];
        if (globalScores.containsKey(c)) {
          globalMembers.putIfAbsent(c, () => []).add(i);
        }
      }
    }

    // Local: seed = note dengan skor term tertinggi; BFS ekspansi hop.
    final scores = <String, double>{
      for (final n in _notes) n.path: _score(terms, '${n.title} ${_contentOf(n)}'),
    };
    final seeds =
        [
          ..._notes.where((n) => (scores[n.path] ?? 0) > 0),
        ]..sort((a, b) {
          final byScore = (scores[b.path] ?? 0).compareTo(scores[a.path] ?? 0);
          if (byScore != 0) return byScore;
          return a.path.compareTo(b.path);
        });
    final picked = <String, GraphRagSource>{};
    void addNote(String path, double score, int hops, {int community = -1}) {
      final existing = picked[path];
      if (existing != null && existing.score >= score) return;
      picked[path] = GraphRagSource(
        path: path,
        title: _titleOf(path),
        score: score,
        hops: hops,
        community: community,
      );
    }

    for (final community in globalScores.keys.take(maxCommunitySummaries)) {
      for (final i in globalMembers[community] ?? const <int>[]) {
        addNote(
          _notes[i].path,
          globalScores[community]!,
          0,
          community: community,
        );
      }
    }
    final visited = <String>{};
    var frontier =
        seeds.take(topK).map((n) => n.path).where(visited.add).toList();
    var hop = 0;
    var decay = 1.0;
    while (frontier.isNotEmpty && hop <= maxHops) {
      final next = <String>[];
      for (final path in frontier) {
        final base = scores[path] ?? 0.05;
        addNote(path, base * decay, hop);
        for (final neighbor in _adjacency[path] ?? const <String>[]) {
          if (visited.add(neighbor)) next.add(neighbor);
        }
      }
      frontier = next;
      hop++;
      decay *= 0.6;
    }

    final ranked = picked.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.path.compareTo(b.path);
      });
    final sources = ranked.take(maxSources).toList();
    return GraphRagAnswer(
      sources: sources,
      context: _context(sources),
      communityCount: communityCount,
      globalQuery: globalScores.isNotEmpty,
    );
  }

  String _titleOf(String path) =>
      _idByPath[path] == null ? path : _notes[_idByPath[path]!].title;

  String _contentOf(IndexedNote n) => n.chunks.isEmpty
      ? n.title
      : [
          for (final c in n.chunks.take(3))
            c.text.length > maxSnippetChars
                ? c.text.substring(0, maxSnippetChars)
                : c.text,
        ].join(' ');

  double _score(Set<String> queryTerms, String text) {
    final textTerms = _terms(text);
    if (textTerms.isEmpty) return 0;
    var hits = 0;
    for (final t in queryTerms) {
      if (textTerms.contains(t)) hits++;
    }
    return hits / queryTerms.length;
  }

  String _summarizeCommunity(List<IndexedNote> members) {
    final titles =
        members.map((m) => m.title.isEmpty ? m.path : m.title).take(8);
    final buffer = StringBuffer('Topik: ')..writeAll(titles, ', ');
    return buffer.length > maxSnippetChars * 2
        ? buffer.toString().substring(0, maxSnippetChars * 2)
        : buffer.toString();
  }

  String _context(List<GraphRagSource> sources) {
    if (sources.isEmpty) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      final note =
          _idByPath[s.path] == null ? null : _notes[_idByPath[s.path]!];
      final snippet = note == null || note.chunks.isEmpty
          ? (note?.title ?? s.title)
          : note.chunks.first.text;
      final trimmed = snippet.length > maxSnippetChars
          ? '${snippet.substring(0, maxSnippetChars)}…'
          : snippet;
      buffer
        ..write('[${i + 1}] ${s.path}')
        ..write('\n$trimmed\n\n');
    }
    return buffer.toString().trimRight();
  }

  static Set<String> _terms(String text) {
    const stopwords = {
      'dan', 'yang', 'dari', 'untuk', 'dengan', 'pada', 'adalah', 'itu',
      'the', 'and', 'for', 'with', 'this', 'that', 'are', 'was', 'apa',
      'bagaimana', 'kenapa', 'berapa',
    };
    return {
      for (final t
          in text.toLowerCase().split(RegExp(r'[^a-z0-9\u00c0-\u024f]+')))
        if (t.length >= 3 && !stopwords.contains(t)) t,
    };
  }
}
