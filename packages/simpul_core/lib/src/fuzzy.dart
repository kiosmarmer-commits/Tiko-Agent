/// Fuzzy term matching (FR-33): tolerant search with 1-2 typos.
///
/// Word-level Damerau-free Levenshtein distance with an early-exit band;
/// tolerance scales with term length (0 for len<=2, 1 for len<=4, 2 beyond)
/// so short words never match everything.
library;

/// Classic Levenshtein distance with a banded early exit.
int editDistance(String a, String b, {int maxEdit = 2}) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > maxEdit) return maxEdit + 1;
  final prev = List<int>.generate(b.length + 1, (j) => j);
  final curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = [
        prev[j] + 1,
        curr[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      if (curr[j] < rowMin) rowMin = curr[j];
    }
    if (rowMin > maxEdit) return maxEdit + 1;
    for (var j = 0; j <= b.length; j++) {
      prev[j] = curr[j];
    }
  }
  return prev[b.length];
}

/// Maximum tolerated edit distance for a query term of [length].
int fuzzyTolerance(int length) {
  if (length <= 2) return 0;
  if (length <= 4) return 1;
  return 2;
}

/// Result of a fuzzy lookup.
class FuzzyHit {
  const FuzzyHit({required this.word, required this.distance});

  final String word;
  final int distance;
}

/// Finds words within tolerance of [term]; exact matches win (distance 0).
List<FuzzyHit> fuzzyMatches(
  Iterable<String> words,
  String term, {
  int? maxEdit,
}) {
  final tolerance = maxEdit ?? fuzzyTolerance(term.length);
  if (tolerance == 0) {
    return words.contains(term) ? [FuzzyHit(word: term, distance: 0)] : const [];
  }
  final hits = <FuzzyHit>[];
  for (final word in words) {
    if (word.isEmpty) continue;
    final d = editDistance(term, word, maxEdit: tolerance);
    if (d <= tolerance) hits.add(FuzzyHit(word: word, distance: d));
  }
  hits.sort((a, b) => a.distance.compareTo(b.distance));
  return hits;
}

/// Splits text into lowercase word tokens for fuzzy scanning.
Set<String> wordTokens(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9\u00C0-\u024F]+'))
    .where((t) => t.isNotEmpty)
    .toSet();
