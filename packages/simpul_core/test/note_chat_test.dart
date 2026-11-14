import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

OllamaChat fakeChat(String reply) => OllamaChat(
      fetch: (url, body) async {
        final messages = body['messages'] as List;
        return {
          'message': {'content': reply},
          'prompt_used': messages.last['content'],
        };
      },
    );

ScannedNote note(String path, String title,
    {List<String> tags = const [], List<ParsedLink> links = const []}) {
  final parsed = ParsedNote(
    path: path,
    title: title,
    props: {},
    tags: tags,
    aliases: [],
    links: links,
    blockIds: [],
    chunks: [],
    wordCount: 0,
    body: '',
  );
  return ScannedNote(
    path: path,
    mtimeNs: 0,
    sizeBytes: 0,
    contentHash: '',
    parsed: parsed,
  );
}

void main() {
  late Directory vault;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('simpul_chat_');
    Directory('${vault.path}/jurnal').createSync();
    File('${vault.path}/ai.md').writeAsStringSync('# AI\nCatatan tentang '
        'embedding vektor dan RAG lokal.\n');
    File('${vault.path}/jurnal/harian.md')
        .writeAsStringSync('# Harian\nAgenda harian biasa.\n');
  });

  tearDown(() async {
    if (await vault.exists()) await vault.delete(recursive: true);
  });

  group('NoteChatSession', () {
    test('note scope: answers with sources and token estimate', () async {
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('Jawaban AI.'),
      );
      final answer = await session.ask(
        'apa itu embedding?',
        scope: NoteChatScope.note,
        notePath: 'ai.md',
      );
      expect(answer.answer, 'Jawaban AI.');
      expect(answer.scope, NoteChatScope.note);
      expect(answer.sources, hasLength(1));
      expect(answer.sources.first.path, 'ai.md');
      expect(answer.contextTokens, greaterThan(0));
    });

    test('folder scope limits to folder notes', () async {
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('ok'),
        maxFolderNotes: 5,
      );
      final answer = await session.ask(
        'agenda',
        scope: NoteChatScope.folder,
        folder: 'jurnal',
      );
      expect(answer.sources.map((s) => s.path), ['jurnal/harian.md']);
    });

    test('vault scope ranks by title/tag overlap', () async {
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('ok'),
      );
      final answer = await session.ask(
        'embedding',
        scope: NoteChatScope.vault,
      );
      expect(answer.sources.first.path, 'ai.md');
    });

    test('deny policy fails closed and logs audit', () async {
      File('${vault.path}/.simpul/ai-permissions.json').parent.createSync();
      File('${vault.path}/.simpul/ai-permissions.json')
          .writeAsStringSync('{"notes": {"ai.md": "tolak"}}');
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('ok'),
      );
      await expectLater(
        session.ask('x', scope: NoteChatScope.note, notePath: 'ai.md'),
        throwsA(isA<AiAccessDenied>()),
      );
      final auditFile = File('${vault.path}/.simpul/ai-audit.jsonl');
      expect(auditFile.existsSync(), isTrue);
      expect(auditFile.readAsStringSync(), contains('note-chat'));
    });

    test('ask policy requires explicit confirmation', () async {
      File('${vault.path}/.simpul/ai-permissions.json').parent.createSync();
      File('${vault.path}/.simpul/ai-permissions.json')
          .writeAsStringSync('{"notes": {"ai.md": "tanya"}}');
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('ok'),
      );
      await expectLater(
        session.ask('x', scope: NoteChatScope.note, notePath: 'ai.md'),
        throwsA(isA<AiAccessDenied>()),
      );
      final answer = await session.ask(
        'x',
        scope: NoteChatScope.note,
        notePath: 'ai.md',
        confirmAsk: true,
      );
      expect(answer.answer, 'ok');
    });

    test('corrupt policy fails closed (denyAll)', () async {
      File('${vault.path}/.simpul/ai-permissions.json').parent.createSync();
      File('${vault.path}/.simpul/ai-permissions.json')
          .writeAsStringSync('{rusak');
      final session = NoteChatSession(
        vaultDir: vault.path,
        chat: fakeChat('ok'),
      );
      await expectLater(
        session.ask('x', scope: NoteChatScope.note, notePath: 'ai.md'),
        throwsA(isA<AiAccessDenied>()),
      );
    });

    test('empty question rejected', () async {
      final session = NoteChatSession(vaultDir: vault.path, chat: fakeChat('x'));
      expect(() => session.ask('  ', scope: NoteChatScope.vault),
          throwsArgumentError);
    });
  });

  group('NoteChatInsertion', () {
    test('block wraps answer in ai callout with model and date', () {
      final block = NoteChatInsertion.block(
        'Baris satu.\n\nBaris dua.',
        model: 'llama3.2',
        now: DateTime(2026, 11, 14, 9, 5),
      );
      expect(block, startsWith('> [!ai] Ditulis AI (model: llama3.2,'));
      expect(block, contains('2026-11-14 09:05'));
      expect(block, contains('> Baris satu.'));
      expect(block, contains('>'));
      expect(block.endsWith('\n'), isTrue);
    });
  });
}
