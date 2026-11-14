import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  group('NoteTemplate.render', () {
    test('substitutes title, date, time, and path', () {
      final out = NoteTemplate.render(
        '# {{title}}\n\nCreated: {{date}} {{time}}\nPath: {{path}}\n',
        title: 'Daily Note',
        path: 'daily/2026-11-14',
        now: DateTime(2026, 11, 14, 9, 5),
      );
      expect(out, contains('# Daily Note'));
      expect(out, contains('Created: 2026-11-14 09:05'));
      expect(out, contains('Path: daily/2026-11-14'));
    });

    test('leaves unknown variables untouched', () {
      final out = NoteTemplate.render('keep {{custom}} and {{title}}',
          title: 'T', extraVars: {'custom': 'replaced'});
      expect(out, 'keep replaced and T');
    });

    test('extraVars override built-ins', () {
      final out = NoteTemplate.render('{{date}}',
          now: DateTime(2026, 1, 2), extraVars: {'date': 'fixed'});
      expect(out, 'fixed');
    });

    test('sanitizeFileName strips unsafe characters', () {
      expect(NoteTemplate.sanitizeFileName('a/b:c*d?"<>|'),
          'a b c d');
      expect(NoteTemplate.sanitizeFileName('   '), 'Untitled');
    });
  });

  group('TemplateStore', () {
    late Directory vault;

    setUp(() async {
      vault = await Directory.systemTemp.createTemp('simpul_tpl_');
    });

    tearDown(() async {
      await vault.delete(recursive: true);
    });

    test('listTemplates returns empty for fresh vault', () async {
      expect(await TemplateStore.listTemplates(vault), isEmpty);
    });

    test('create then list and read round-trips', () async {
      await TemplateStore.create(vault, 'Daily', '# {{title}}\n{{date}}');
      await TemplateStore.create(vault, 'Meeting', '## Agenda');
      final list = await TemplateStore.listTemplates(vault);
      expect(list.map((t) => t.name), ['Daily', 'Meeting']);
      final body = await TemplateStore.read(vault, 'Daily');
      expect(body, '# {{title}}\n{{date}}');
    });
  });
}
