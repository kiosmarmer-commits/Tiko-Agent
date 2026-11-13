import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote note(String path, List<String> targets) => IndexedNote(
      path: path,
      title: path,
      mtimeNs: 0,
      sizeBytes: 0,
      contentHash: 'hash-$path',
      wordCount: 1,
      props: const {},
      tags: const [],
      aliases: const [],
      links: [
        for (final t in targets)
          ParsedLink(
            target: t,
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: false,
            offset: 0,
          ),
      ],
      chunks: const [],
    );

/// Two 5-node cliques connected by a single bridge edge.
GraphCsr twoCliques() {
  final links = <String, List<String>>{};
  for (var i = 0; i < 5; i++) {
    for (var j = 0; j < 5; j++) {
      if (i == j) continue;
      links.putIfAbsent('a$i.md', () => []).add('a$j.md');
    }
  }
  for (var i = 0; i < 5; i++) {
    for (var j = 0; j < 5; j++) {
      if (i == j) continue;
      links.putIfAbsent('b$i.md', () => []).add('b$j.md');
    }
  }
  links['a0.md']!.add('b4.md');
  return GraphCsr.build([
    for (final entry in links.entries) note(entry.key, entry.value),
  ]);
}

void main() {
  test('detects two communities in two cliques joined by a bridge', () {
    final graph = twoCliques();
    final result = CommunityDetector.louvain(graph);

    expect(result.communityCount, 2);
    final commA = result.communityOf[0];
    final commB = result.communityOf[5];
    expect(commA, isNot(commB));
    for (var i = 0; i < 5; i++) {
      expect(result.communityOf[i], commA);
      expect(result.communityOf[5 + i], commB);
    }
    expect(result.modularity, greaterThan(0.3));
  });

  test('is deterministic across runs', () {
    final a = CommunityDetector.louvain(twoCliques());
    final b = CommunityDetector.louvain(twoCliques());
    expect(a.communityOf, b.communityOf);
    expect(a.modularity, b.modularity);
  });

  test('handles empty, single, and orphan-only graphs', () {
    expect(CommunityDetector.louvain(GraphCsr.build([])).communityCount, 0);

    final single = GraphCsr.build([note('solo.md', [])]);
    final result = CommunityDetector.louvain(single);
    expect(result.communityCount, 1);
    expect(result.modularity, 0);

    final orphans = GraphCsr.build(
      [note('x.md', []), note('y.md', []), note('z.md', [])],
    );
    expect(CommunityDetector.louvain(orphans).communityCount, 3);
  });

  test('complete graph stays in one community', () {
    final clique = GraphCsr.build([
      for (var i = 0; i < 6; i++)
        note(
          'k$i.md',
          [for (var j = 0; j < 6; j++) if (j != i) 'k$j'],
        ),
    ]);
    final result = CommunityDetector.louvain(clique);
    expect(result.communityCount, 1);
    expect(result.modularity, closeTo(0, 1e-9));
  });

  test('ring graph splits without crashing and keeps positive modularity', () {
    final ring = GraphCsr.build([
      for (var i = 0; i < 12; i++) note('r$i.md', ['r${(i + 1) % 12}']),
    ]);
    final result = CommunityDetector.louvain(ring);
    expect(result.communityCount, inInclusiveRange(1, 12));
    expect(result.modularity, greaterThanOrEqualTo(0));
    expect(result.communityOf.length, 12);
  });
}
