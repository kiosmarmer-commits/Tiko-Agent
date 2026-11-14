import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JsonVaultIndex index;
  late InMemorySemanticIndex semantic;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simpul-rag-test');
    index = JsonVaultIndex('${tmp.path}/index.json');
    semantic = InMemorySemanticIndex(HashingEmbedder());
    await index.replaceAll([
      _note(
        'ai/jaringan.md',
        title: 'Jaringan Saraf',
        chunks: [
          const NoteChunk(
            headingPath: '',
            startChar: 0,
            endChar: 120,
            text:
                'Backpropagation menghitung gradien error dengan aturan rantai '
                'untuk memperbarui bobot jaringan saraf tiruan.',
          ),
          const NoteChunk(
            headingPath: 'Bagian 1',
            startChar: 120,
            endChar: 240,
            text:
                'Convolutional neural network unggul untuk klasifikasi citra '
                'karena berbagi bobot pada lapisan konvolusi.',
          ),
        ],
      ),
      _note(
        'masak/resep.md',
        title: 'Resep Nasi Goreng',
        chunks: [
          const NoteChunk(
            headingPath: '',
            startChar: 0,
            endChar: 100,
            text:
                'Nasi goreng dimasak dengan bawang putih, kecap manis, dan '
                'telur di atas wajan panas.',
          ),
        ],
      ),
    ]);
    await semantic.upsert([
      const ChunkInput(
        notePath: 'ai/jaringan.md',
        ord: 0,
        headingPath: '',
        text: 'Backpropagation menghitung gradien error untuk jaringan saraf.',
        hash: 'h-1',
      ),
      const ChunkInput(
        notePath: 'ai/jaringan.md',
        ord: 1,
        headingPath: 'Bagian 1',
        text: 'Convolutional neural network untuk citra.',
        hash: 'h-2',
      ),
      const ChunkInput(
        notePath: 'masak/resep.md',
        ord: 0,
        headingPath: '',
        text: 'Nasi goreng dengan bawang putih dan kecap manis.',
        hash: 'h-3',
      ),
    ]);
  });

  tearDown(() async {
    await index.close();
    await semantic.close();
    await tmp.delete(recursive: true);
  });

  test('llm mode answers with citations and the expected prompts', () async {
    final chat = _FakeChat('Backpropagation memperbarui bobot [1].');
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
      semantic: semantic,
      chat: chat,
    );
    final answer = await answerer.ask('bagaimana backpropagation bekerja');

    expect(answer.mode, 'llm');
    expect(answer.answer, 'Backpropagation memperbarui bobot [1].');
    expect(answer.citations, isNotEmpty);
    expect(answer.citations.first.path, 'ai/jaringan.md');
    expect(chat.lastSystem, contains('sitasi'));
    expect(chat.lastPrompt, contains('Pertanyaan:'));
    expect(chat.lastPrompt, contains('[1] ai/jaringan.md'));
  });

  test('extractive mode without a chat returns evidence as-is', () async {
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
      semantic: semantic,
    );
    final answer = await answerer.ask('nasi goreng');

    expect(answer.mode, 'extractive');
    expect(answer.answer, contains('[1] masak/resep.md'));
    expect(answer.citations.first.path, 'masak/resep.md');
  });

  test('not_found when no path is allowed (AI-22)', () async {
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
      semantic: semantic,
    );
    final answer = await answerer.ask(
      'nasi goreng',
      allowedPaths: const {},
    );

    expect(answer.mode, 'not_found');
    expect(answer.citations, isEmpty);
  });

  test('token budget skips chunks that no longer fit (AI-23)', () async {
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
      semantic: semantic,
      tokenBudget: 10,
    );
    final answer = await answerer.ask('nasi goreng backpropagation citra');

    expect(answer.citations.length, 1);
    expect(answer.usedTokens, greaterThan(0));
  });

  test('allowedPaths restricts citations to permitted notes', () async {
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
      semantic: semantic,
    );
    final answer = await answerer.ask(
      'nasi goreng jaringan citra',
      allowedPaths: {'masak/resep.md'},
    );

    expect(answer.citations, isNotEmpty);
    for (final chunk in answer.citations) {
      expect(chunk.path, 'masak/resep.md');
    }
  });

  test('lexicalPrefilter returns candidate paths (AI-30)', () async {
    final paths = await lexicalPrefilter(index, 'nasi goreng');
    expect(paths, {'masak/resep.md'});
  });

  test('works without a semantic index (lexical only)', () async {
    final answerer = VaultAnswerer(
      index: index,
      embedder: HashingEmbedder(),
    );
    final answer = await answerer.ask('backpropagation');

    expect(answer.mode, 'extractive');
    expect(answer.citations, isNotEmpty);
    expect(answer.citations.first.path, 'ai/jaringan.md');
  });
}

IndexedNote _note(
  String path, {
  required String title,
  List<NoteChunk> chunks = const [],
}) =>
    IndexedNote(
      path: path,
      title: title,
      mtimeNs: 0,
      sizeBytes: 0,
      contentHash: 'hash-$path',
      wordCount: 0,
      props: const {},
      tags: const [],
      aliases: const [],
      links: const [],
      chunks: chunks,
    );

class _FakeChat implements OllamaChat {
  _FakeChat(this._reply);

  final String _reply;
  String? lastPrompt;
  String? lastSystem;

  @override
  Future<String> complete(String prompt, {String? system}) async {
    lastPrompt = prompt;
    lastSystem = system;
    return _reply;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
