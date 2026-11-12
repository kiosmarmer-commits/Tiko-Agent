import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

const sampleSkill = '''
---
name: pdf-report
description: Generate a PDF report from data
license: MIT
allowed-tools:
  - read_file
  - write_file
metadata:
  triggers:
    - laporan pdf
  author: tiko
---

## Steps
1. Read the data file.
2. Render and write the PDF.
''';

void main() {
  group('AgentSkillManifest', () {
    test('parses valid SKILL.md', () {
      final parsed = AgentSkillManifest.parse(sampleSkill);
      expect(parsed.errors, isEmpty);
      expect(parsed.manifest.name, 'pdf-report');
      expect(parsed.manifest.description, 'Generate a PDF report from data');
      expect(parsed.manifest.license, 'MIT');
      expect(parsed.manifest.allowedTools, ['read_file', 'write_file']);
      expect(parsed.manifest.metadata['author'], 'tiko');
      expect((parsed.manifest.metadata['triggers'] as List).first,
          'laporan pdf');
      expect(parsed.body, contains('## Steps'));
    });

    test('rejects missing frontmatter', () {
      final parsed = AgentSkillManifest.parse('just markdown');
      expect(parsed.errors, contains('missing YAML frontmatter (must start with ---)'));
      expect(parsed.manifest.isValid, isFalse);
    });

    test('rejects unclosed frontmatter', () {
      final parsed = AgentSkillManifest.parse('---\nname: x\ndescription: y\n');
      expect(parsed.errors, contains('frontmatter is not closed with ---'));
    });

    test('validates name pattern and length', () {
      final bad = const AgentSkillManifest(
          name: 'Invalid Name!', description: 'desc');
      expect(bad.validate(), isNotEmpty);
      final long = AgentSkillManifest(
          name: 'a' * 65, description: 'desc');
      expect(long.validate(), contains('name must be at most 64 characters'));
    });

    test('validates description length', () {
      final bad = AgentSkillManifest(name: 'ok-name', description: 'd' * 1025);
      expect(
          bad.validate(),
          contains('description must be at most 1024 characters'));
    });

    test('round trip markdown serialization', () {
      final parsed = AgentSkillManifest.parse(sampleSkill);
      final markdown = parsed.manifest.toMarkdown(parsed.body);
      final reparsed = AgentSkillManifest.parse(markdown);
      expect(reparsed.errors, isEmpty);
      expect(reparsed.manifest.name, 'pdf-report');
      expect(reparsed.manifest.allowedTools, ['read_file', 'write_file']);
      expect(reparsed.body, contains('## Steps'));
    });

    test('description with colon is quoted and survives round trip', () {
      const manifest = AgentSkillManifest(
          name: 'colon-skill', description: 'does things: quickly');
      final markdown = manifest.toMarkdown('body');
      final reparsed = AgentSkillManifest.parse(markdown);
      expect(reparsed.errors, isEmpty);
      expect(reparsed.manifest.description, 'does things: quickly');
    });
  });

  group('AgentSkillConverter', () {
    const converter = AgentSkillConverter();

    test('standard skill becomes Tiko skill in trial status', () {
      final parsed = AgentSkillManifest.parse(sampleSkill);
      final skill = converter.toTikoSkill(parsed.manifest, parsed.body);
      expect(skill.slug, 'pdf-report');
      expect(skill.tools, ['read_file', 'write_file']);
      expect(skill.triggers, ['laporan pdf']);
      expect(skill.status, SkillStatus.trial);
      expect(skill.body, contains('## Steps'));
    });

    test('Tiko skill exports to standard SKILL.md and back', () {
      final skill = Skill(
        slug: 'ringkas-waktu',
        name: 'ringkas-waktu',
        description: 'Ringkas pertanyaan waktu',
        body: 'Pakai tool datetime.',
        triggers: ['waktu', 'jam'],
        tools: ['datetime'],
      );
      final markdown = converter.toSkillMarkdown(skill);
      final parsed = AgentSkillManifest.parse(markdown);
      expect(parsed.errors, isEmpty);
      final restored = converter.toTikoSkill(parsed.manifest, parsed.body);
      expect(restored.slug, 'ringkas-waktu');
      expect(restored.triggers, ['waktu', 'jam']);
      expect(restored.tools, ['datetime']);
      expect(restored.body, 'Pakai tool datetime.');
    });
  });
}
