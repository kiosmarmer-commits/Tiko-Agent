import 'dart:io';

import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

Future<Directory> _vault(Map<String, String> notes) async {
  final dir = await Directory.systemTemp.createTemp('tiko-editor');
  for (final entry in notes.entries) {
    final file = File('${dir.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return dir;
}

void main() {
  late Directory vault;

  tearDown(() => vault.delete(recursive: true));

  group('VaultLinkResolver', () {
    test('resolve by path, basename, dan alias', () async {
      vault = await _vault({
        'catatan/ide.md': '# Ide\n\nisi\n',
        'proyek/ide-lama.md': '---\naliases: [Ide Besar]\n---\n\nisi\n',
      });
      final notes = await VaultScanner.scan(vault.path);
      final resolver = VaultLinkResolver(notes);
      expect(resolver.resolve('catatan/ide'), 'catatan/ide.md');
      expect(resolver.resolve('ide'), 'catatan/ide.md');
      expect(resolver.resolve('ide.md'), 'catatan/ide.md');
      expect(resolver.resolve('Ide Besar'), 'proyek/ide-lama.md');
      expect(resolver.resolve('tidak-ada'), isNull);
    });

    test('completions: prefix basename menang, lalu contains', () async {
      vault = await _vault({
        'idea.md': '# Idea\n',
        'catatan/ide-kecil.md': '# Ide Kecil\n',
        'lain.md': '# Lain\n',
      });
      final notes = await VaultScanner.scan(vault.path);
      final resolver = VaultLinkResolver(notes);
      final result = resolver.completions('ide');
      expect(result.first.path, anyOf('idea', 'catatan/ide-kecil'));
      expect(result.length, 2);
      expect(resolver.completions('zzz'), isEmpty);
    });

    test('backlinkMap menghitung sumber yang resolve', () async {
      vault = await _vault({
        'a.md': 'lihat [[b]]\n',
        'c.md': 'juga [[b]] dan [[a]]\n',
        'b.md': '# B\n',
      });
      final notes = await VaultScanner.scan(vault.path);
      final resolver = VaultLinkResolver(notes);
      expect(resolver.backlinks['b.md'], containsAll(['a.md', 'c.md']));
      expect(resolver.backlinks['a.md'], ['c.md']);
      expect(resolver.backlinks.containsKey('c.md'), isFalse);
    });
  });

  group('NoteEditor', () {
    test('load, edit, dirty, undo/redo', () async {
      vault = await _vault({'a.md': 'satu\n'});
      final notes = await VaultScanner.scan(vault.path);
      final editor = NoteEditor(
        vaultDir: vault.path,
        resolver: VaultLinkResolver(notes),
      );
      await editor.load('a.md');
      expect(editor.dirty, isFalse);
      editor.text = 'satu dua\n';
      expect(editor.dirty, isTrue);
      expect(editor.undo(), isTrue);
      expect(editor.text, 'satu\n');
      expect(editor.redo(), isTrue);
      expect(editor.text, 'satu dua\n');
      expect(editor.canRedo, isFalse);
    });

    test('undo stack dibatasi dan redo bersih saat edit baru', () async {
      vault = await _vault({'a.md': ''});
      final editor = NoteEditor(vaultDir: vault.path);
      await editor.load('a.md');
      for (var i = 0; i < 600; i++) {
        editor.text = 'v$i';
      }
      var undone = 0;
      while (editor.undo()) {
        undone++;
      }
      expect(undone, 500);
      editor.redo();
      editor.text = 'baru';
      expect(editor.canRedo, isFalse);
    });

    test('save atomik: tidak ada .tmp tersisa, isi benar', () async {
      vault = await _vault({'folder/a.md': 'lama\n'});
      final editor = NoteEditor(vaultDir: vault.path);
      await editor.load('folder/a.md');
      editor.text = 'baru\n';
      await editor.save();
      expect(editor.dirty, isFalse);
      expect(File('${vault.path}/folder/a.md').readAsStringSync(), 'baru\n');
      expect(
        Directory('${vault.path}/folder')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('links: resolved dan unresolved dengan alias/anchor/embed', () async {
      vault = await _vault({
        'a.md': 'ke [[b#Bagian|b bagian]], ![[]], dan [[hantu]]\n',
        'b.md': '# B\n\n## Bagian\n\nx\n',
      });
      final notes = await VaultScanner.scan(vault.path);
      final editor = NoteEditor(
        vaultDir: vault.path,
        resolver: VaultLinkResolver(notes),
      );
      await editor.load('a.md');
      final links = editor.links();
      expect(links, hasLength(2));
      final keB = links[0];
      expect(keB.resolved, isTrue);
      expect(keB.resolvedPath, 'b.md');
      expect(keB.link.anchor, 'Bagian');
      expect(keB.link.alias, 'b bagian');
      expect(links[1].resolved, isFalse);
    });

    test('insertWikilink menyisipkan di offset dan kembalikan kursor', () async {
      vault = await _vault({'a.md': 'halo dunia'});
      final editor = NoteEditor(vaultDir: vault.path);
      await editor.load('a.md');
      final cursor = editor.insertWikilink(4, 'b', alias: 'B');
      expect(editor.text, 'halo[[b|B]] dunia');
      expect(cursor, 'halo'.length + '[[b|B]]'.length);
      editor.undo();
      expect(editor.text, 'halo dunia');
    });

    test('backlinks catatan terbuka dari snapshot', () async {
      vault = await _vault({
        'a.md': '# A\n',
        'b.md': 'rujuk [[a]]\n',
      });
      final notes = await VaultScanner.scan(vault.path);
      final editor = NoteEditor(
        vaultDir: vault.path,
        resolver: VaultLinkResolver(notes),
      );
      await editor.load('a.md');
      expect(editor.backlinks(), ['b.md']);
    });
  });
}
