import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

IndexedNote note(String path, List<(String, bool)> links) => IndexedNote(
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
        for (final (target, embed) in links)
          ParsedLink(
            target: target,
            anchor: '',
            alias: '',
            kind: 'wikilink',
            embed: embed,
            offset: 0,
          ),
      ],
      chunks: const [],
    );

void main() {
  test('builds CSR with sorted dense ids', () {
    final graph = GraphCsr.build([
      note('c.md', [('a', false)]),
      note('a.md', [('b', false), ('b', false), ('a', false)]),
      note('b.md', []),
    ]);
    expect(graph.nodeCount, 3);
    expect(graph.paths, ['a.md', 'b.md', 'c.md']);
    expect(graph.edgeCount, 2);
    expect(graph.outDegree(0), 1);
    expect(graph.outDegree(1), 0);
    expect(graph.outDegree(2), 1);
    expect(graph.inDegree(0), 1);
    expect(graph.inDegree(1), 1);
  });

  test('skips embeds, self-links, and unresolved targets', () {
    final graph = GraphCsr.build([
      note('a.md', [('a', false), ('b', true), ('hilang', false), ('b', false)]),
      note('b.md', []),
    ]);
    expect(graph.edgeCount, 1);
    expect(graph.outDegree(0), 1);
    expect(graph.orphanNodes(), isEmpty);
  });

  test('computes N-hop neighborhoods including the origin', () {
    final graph = GraphCsr.build([
      note('a.md', [('b', false)]),
      note('b.md', [('c', false)]),
      note('c.md', [('d', false)]),
      note('d.md', []),
    ]);
    final one = graph.neighborhood(0, 1);
    expect(one, {0, 1});
    final two = graph.neighborhood(0, 2);
    expect(two, {0, 1, 2});
    final three = graph.neighborhood(0, 3);
    expect(three, {0, 1, 2, 3});
  });

  test('detects orphans', () {
    final graph = GraphCsr.build([
      note('a.md', [('b', false)]),
      note('b.md', []),
      note('yatim.md', []),
    ]);
    expect(graph.orphanNodes(), [2]);
  });
}
