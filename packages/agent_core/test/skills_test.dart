import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  test('parse skill frontmatter', () {
    const md = '''
---
name: demo
description: Contoh skill
triggers: ["alpha", "beta"]
tools: [datetime, calc]
version: 2
status: trial
---

## Langkah
1. Lakukan sesuatu
''';
    final s = SkillParser.parse(md, slug: 'demo');
    expect(s, isNotNull);
    expect(s!.name, 'demo');
    expect(s.triggers, ['alpha', 'beta']);
    expect(s.tools, ['datetime', 'calc']);
    expect(s.status, SkillStatus.trial);
    expect(s.body, contains('Langkah'));
  });

  test('validator rejects secrets', () {
    final s = Skill(
      slug: 'bad',
      name: 'bad',
      description: 'x',
      body: 'use api_key=sk-abcdefghijklmnopqrstuvwxyz1234',
    );
    expect(SkillValidator.validate(s), isNotNull);
  });

  test('validator rejects unknown tools', () {
    final s = Skill(
      slug: 'x',
      name: 'x',
      description: 'ok',
      body: '## Langkah\n1. hi',
      tools: ['not_a_real_tool'],
    );
    expect(SkillValidator.validate(s, knownTools: {'datetime'}), isNotNull);
  });

  test('draft builder produces valid skill', () {
    final md = SkillDraftBuilder.build(
      name: 'test-skill',
      description: 'Skill uji',
      triggers: ['uji'],
      tools: ['datetime'],
      steps: ['Panggil datetime', 'Jawab user'],
    );
    final s = SkillParser.parse(md);
    expect(s, isNotNull);
    expect(SkillValidator.validate(s!, knownTools: {'datetime'}), isNull);
  });

  test('successful usage and feedback never auto-approve a skill', () {
    final reg = SkillRegistry();
    final s = Skill(
      slug: 't',
      name: 't',
      description: 'd',
      body: 'b',
      status: SkillStatus.trial,
    );
    reg.register(s);
    for (var i = 0; i < 5; i++) {
      reg.recordUse('t', success: true);
      reg.applyFeedback('t', positive: true);
    }
    expect(reg.get('t')!.status, SkillStatus.trial);
  });

  test('skills loaded from files cannot self-assert an approved status', () async {
    final dir = Directory.systemTemp.createTempSync('tiko-skills-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final skillDir = Directory('${dir.path}/untrusted')..createSync();
    File('${skillDir.path}/SKILL.md').writeAsStringSync('''
---
name: Untrusted
description: Unsafe frontmatter
status: approved
triggers: [run]
---

Instruction body.
''');
    final registry = SkillRegistry();
    await registry.loadFromDirectory(dir.path);
    expect(registry.get('untrusted')?.status, SkillStatus.draft);
    expect(registry.get('untrusted')?.approvedBy, isNull);
  });

  test('feedback few-shot', () {
    final fb = FeedbackStore();
    fb.add(
      FeedbackEntry(
        sessionId: 's',
        rating: 1,
        input: 'hitung 2+2',
        output: '4',
      ),
    );
    fb.add(
      FeedbackEntry(sessionId: 's', rating: -1, input: 'halo', output: 'err'),
    );
    final few = fb.positiveFewShot(similarTo: 'hitung 3+3');
    expect(few, hasLength(1));
  });
}
