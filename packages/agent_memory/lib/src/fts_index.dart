import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Portable inverted-index FTS with Okapi BM25 ranking, no native sqlite.
///
/// Scores are normalized relative to the best hit of the query so
/// downstream consumers, such as importance weighting and the reranker
/// clamps, keep a stable scale regardless of corpus size.
class FtsIndex {
  FtsIndex(this.path, {this.k1 = 1.2, this.b = 0.75});

  final String path;

  /// BM25 term-frequency saturation, k1, and length normalization, b.
  final double k1;
  final double b;

  /// term -> docId -> term frequency in that doc.
  final Map<String, Map<String, int>> _postings = {};

  /// docId -> token count, duplicates included.
  final Map<String, int> _docLens = {};

  /// id -> text.
  final Map<String, String> _docs = {};

  Future<void> load() async {
    final f = File(path);
    if (!await f.exists()) return;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final docs = json['docs'] as Map<String, dynamic>? ?? {};
      docs.forEach((k, v) {
        _docs[k] = v as String;
        _index(k, v);
      });
    } catch (_) {}
  }

  Future<void> save() async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(jsonEncode({'docs': _docs}));
  }

  void upsert(String id, String text) {
    // remove old postings
    if (_docs.containsKey(id)) {
      for (final t in _tokens(_docs[id]!)) {
        _postings[t]?.remove(id);
      }
    }
    _docs[id] = text;
    _index(id, text);
  }

  void remove(String id) {
    final text = _docs.remove(id);
    _docLens.remove(id);
    if (text == null) return;
    for (final t in _tokens(text)) {
      _postings[t]?.remove(id);
    }
  }

  /// Okapi BM25 ranking normalized to the best hit. Uses Lucene-style
  /// IDF, always positive, so tiny corpora still rank sensibly. Ties are
  /// broken deterministically by document id.
  List<({String id, String text, double score})> search(
    String query, {
    int k = 8,
  }) {
    final q = _tokens(query);
    if (q.isEmpty || _docs.isEmpty) return [];
    final n = _docs.length;
    var totalLen = 0;
    for (final len in _docLens.values) {
      totalLen += len;
    }
    if (totalLen <= 0) return [];
    final avgdl = totalLen / n;
    final scores = <String, double>{};
    for (final t in q) {
      final postings = _postings[t];
      if (postings == null || postings.isEmpty) continue;
      final df = postings.length;
      final idf = math.log(1.0 + (n - df + 0.5) / (df + 0.5));
      postings.forEach((id, tf) {
        final dl = _docLens[id] ?? 1;
        final norm = 1.0 - b + b * dl / avgdl;
        final gain = tf * (k1 + 1.0) / (tf + k1 * norm);
        scores[id] = (scores[id] ?? 0) + idf * gain;
      });
    }
    if (scores.isEmpty) return [];
    final ranked = scores.entries.toList()
      ..sort((x, y) {
        final byScore = y.value.compareTo(x.value);
        if (byScore != 0) return byScore;
        return x.key.compareTo(y.key);
      });
    final maxScore = ranked.first.value;
    if (maxScore <= 0) return [];
    return ranked.take(k).map((e) {
      final text = _docs[e.key] ?? '';
      return (id: e.key, text: text, score: e.value / maxScore);
    }).toList();
  }

  void _index(String id, String text) {
    final tokens = _tokenList(text);
    _docLens[id] = tokens.length;
    for (final t in tokens) {
      final perDoc = _postings.putIfAbsent(t, () => {});
      perDoc[id] = (perDoc[id] ?? 0) + 1;
    }
  }

  List<String> _tokenList(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1)
      .toList();

  Set<String> _tokens(String s) => _tokenList(s).toSet();
}
