import 'dart:convert';
import 'dart:io';

/// Lightweight inverted-index FTS substitute (portable, no native sqlite).
class FtsIndex {
  FtsIndex(this.path);

  final String path;
  final Map<String, Set<String>> _postings = {}; // token → docIds
  final Map<String, String> _docs = {}; // id → text

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
    if (text == null) return;
    for (final t in _tokens(text)) {
      _postings[t]?.remove(id);
    }
  }

  List<({String id, String text, double score})> search(
    String query, {
    int k = 8,
  }) {
    final q = _tokens(query);
    if (q.isEmpty) return [];
    final scores = <String, double>{};
    for (final t in q) {
      final docs = _postings[t];
      if (docs == null) continue;
      for (final id in docs) {
        scores[id] = (scores[id] ?? 0) + 1.0;
      }
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.take(k).map((e) {
      final text = _docs[e.key] ?? '';
      final score = e.value / q.length;
      return (id: e.key, text: text, score: score);
    }).toList();
  }

  void _index(String id, String text) {
    for (final t in _tokens(text)) {
      _postings.putIfAbsent(t, () => {}).add(id);
    }
  }

  Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1)
      .toSet();
}
