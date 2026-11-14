import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('editDistance', () {
    test('identical and empty cases', () {
      expect(editDistance('abc', 'abc'), 0);
      expect(editDistance('', ''), 0);
      expect(editDistance('abc', ''), 3);
    });

    test('counts insertions, deletions, substitutions', () {
      expect(editDistance('kitten', 'sitting', maxEdit: 3), 3);
      expect(editDistance('cat', 'cart', maxEdit: 2), 1);
      expect(editDistance('cat', 'act', maxEdit: 2), 2);
    });

    test('early exit beyond band', () {
      expect(editDistance('abc', 'zzzzzzz', maxEdit: 2), greaterThan(2));
    });
  });

  group('fuzzyTolerance', () {
    test('scales with length', () {
      expect(fuzzyTolerance(1), 0);
      expect(fuzzyTolerance(2), 0);
      expect(fuzzyTolerance(4), 1);
      expect(fuzzyTolerance(8), 2);
    });
  });

  group('fuzzyMatches', () {
    test('exact match wins with distance 0', () {
      final hits = fuzzyMatches(['embedding', 'vektor'], 'embedding');
      expect(hits.single.word, 'embedding');
      expect(hits.single.distance, 0);
    });

    test('tolerates one typo on short words', () {
      final hits = fuzzyMatches(['graf', 'gras', 'gran'], 'graf');
      expect(hits.first.word, 'graf');
      expect(hits.map((h) => h.word), containsAll(['gras', 'gran']));
    });

    test('zero tolerance rejects typos', () {
      expect(fuzzyMatches(['ab', 'ax'], 'ab'), hasLength(1));
      expect(fuzzyMatches(['ab'], 'ax'), isEmpty);
    });
  });
}
