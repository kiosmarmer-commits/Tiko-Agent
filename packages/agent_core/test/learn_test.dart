import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('LearnCommand.parse', () {
    test('bukan /learn menghasilkan null', () {
      expect(LearnCommand.parse('buat file x'), isNull);
      expect(LearnCommand.parse('/learning sesuatu'), isNull);
    });

    test('/learn tanpa argumen = dari percakapan', () {
      final r = LearnCommand.parse('/learn')!;
      expect(r.fromConversation, isTrue);
      expect(r.sources.single.type, 'conversation');
    });

    test('deteksi URL, direktori, dan file', () {
      final r = LearnCommand.parse(
        '/learn https://docs.example.id/api ./docs /tmp/notes.txt',
      )!;
      expect(r.sources.map((s) => s.type).toList(),
          ['url', 'dir', 'file']);
      expect(r.sources.first.value, 'https://docs.example.id/api');
    });

    test('notes: membawa teks tempel multi-baris', () {
      final r = LearnCommand.parse(
        '/learn notes: langkah 1\nlangkah 2\n--focus deploy',
      )!;
      expect(r.sources.single.type, 'notes');
      expect(r.sources.single.value, contains('langkah 1'));
      expect(r.focus, 'deploy');
    });

    test('kata kunci conversation di antara sumber lain', () {
      final r = LearnCommand.parse('/learn conversation ./docs')!;
      expect(r.fromConversation, isTrue);
      expect(r.sources, hasLength(2));
    });

    test('flag --focus dipisahkan dari sumber', () {
      final r = LearnCommand.parse('/learn ./api --focus integrasi webhook')!;
      expect(r.focus, 'integrasi webhook');
      expect(r.sources.single.value, './api');
    });
  });

  group('LearnPrompt', () {
    test('kontrak authoring memuat standar house', () {
      final prompt = LearnPrompt.userPrompt(
        LearnRequest(sources: [LearnSource(type: 'url', value: 'https://x.dev')], focus: 'api'),
      );
      expect(prompt, contains('60 karakter'));
      expect(prompt, contains('## Langkah'));
      expect(prompt, contains('skill-markdown'));
      expect(prompt, contains('https://x.dev'));
      expect(prompt, contains('api'));
    });
  });

  group('LearnOutput.extractSkillMarkdown', () {
    const skill = '---\nname: Deploy\n'
        'description: Deploy ringkas\n'
        'triggers: ["deploy"]\n'
        'tools: [shell]\n'
        'version: 1\n'
        'status: draft\n'
        '---\n\n## Langkah\n1. build\n';

    test('mengambil blok skill-markdown', () {
      final md = LearnOutput.extractSkillMarkdown(
        'Ini skillnya:\n```skill-markdown\n$skill```',
      );
      expect(md, startsWith('---'));
      expect(md, contains('## Langkah'));
    });

    test('fallback ke fence generik yang dimulai frontmatter', () {
      final md = LearnOutput.extractSkillMarkdown('```markdown\n$skill```');
      expect(md, isNotNull);
    });

    test('null bila tidak ada blok frontmatter', () {
      expect(LearnOutput.extractSkillMarkdown('biasa saja ```dart\ncode```'),
          isNull);
    });

    test('SkillParser dapat memarse hasil ekstraksi', () {
      final md = LearnOutput.extractSkillMarkdown('```skill-markdown\n$skill```')!;
      final parsed = SkillParser.parse(md);
      expect(parsed, isNotNull);
      expect(parsed!.slug, 'deploy');
      expect(parsed.description, 'Deploy ringkas');
    });
  });
}
