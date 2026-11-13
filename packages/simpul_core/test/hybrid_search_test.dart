import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late JsonVaultIndex index;
  late InMemorySemanticIndex semantic;
  late HybridSearcher hybrid;

  setUp(() async {
    index = JsonVaultIndex('/tmp/simpul-hybrid-index.json');
    await index.replaceAll(const [
      IndexedNote(
        path: 'ai/jaringan.md',
        title: 'Jaringan Saraf',
        mtimeNs: 0,
        sizeBytes: 0,
        contentHash: 'h1',
        wordCount: 20,
        props: {},
        tags: [],
        aliases: [],
        links: [],
        chunks: [
          NoteChunk(
            headingPath: 'Pengantar',
            startChar: 0,
            endChar: 60,
            text: 'Jaringan saraf tiruan belajar dari data gambar berlabel.',
          ),
        ],
      ),
      IndexedNote(
        path: 'masakan/rendang.md',
        title: 'Rendang',
        mtimeNs: 0,
        sizeBytes: 0,
        contentHash: 'h2',
        wordCount: 20,
        props: {},
        tags: [],
        aliases: [],
        links: [],
        chunks: [
          NoteChunk(
            headingPath: 'Bahan',
            startChar: 0,
            endChar: 60,
            text: 'Rendang dimasak dengan santan dan daging sapi.',
          ),
        ],
      ),
    ]);

    final embedder = HashingEmbedder(dim: 96);
    semantic = InMemorySemanticIndex(embedder);
    await semantic.replaceAll(const [
      ChunkInput(
        notePath: 'ai/jaringan.md',
        ord: 0,
        headingPath: 'Pengantar',
        text: 'Jaringan saraf tiruan belajar dari data gambar berlabel.',
        hash: 'h1:0',
      ),
      ChunkInput(
        notePath: 'masakan/rendang.md',
        ord: 0,
        headingPath: 'Bahan',
        text: 'Rendang dimasak dengan santan dan daging sapi.',
        hash: 'h2:0',
      ),
    ]);
    hybrid = HybridSearcher(index: index, semantic: semantic, embedder: embedder);
  });

  tearDown(() async {
    await index.close();
    await semantic.close();
  });

  test('hybrid fusion surfaces semantic-only matches (AI-20)', () async {
    final hits = await hybrid.search('teknik deep learning untuk citra');
    expect(hits.map((h) => h.path), contains('ai/jaringan.md'));
    final lexicalOnly = await hybrid.search(
      'teknik deep learning untuk citra',
      useSemantic: false,
    );
    expect(lexicalOnly, isEmpty);
  });

  test('lexical matches keep their snippets in fused results', () async {
    final hits = await hybrid.search('santan');
    final rendang = hits.firstWhere((h) => h.path == 'masakan/rendang.md');
    expect(rendang.snippet, isNotEmpty);
    expect(rendang.title, 'Rendang');
  });

  test('exactTopK ranks identical text first', () {
    final embedder = HashingEmbedder(dim: 64);
    final vectors = [
      embedder.embed('alpha beta gamma'),
      embedder.embed('alpha beta gamma'),
      embedder.embed('sama sekali berbeda'),
    ];
    final top = exactTopK(embedder.embed('alpha beta gamma'), vectors, 2);
    expect(top.toSet(), {0, 1});
  });
}
