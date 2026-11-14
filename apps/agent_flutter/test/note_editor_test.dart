import 'dart:io';

import 'package:agent_flutter/ui/note_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpul_core/simpul_core.dart';

void main() {
  late Directory vault;

  setUp(() async {
    vault = await Directory.systemTemp.createTemp('tiko-editor-ui');
    File('${vault.path}/a.md').writeAsStringSync('# Judul A\n\nisi **tebal** `kode`\n');
    File('${vault.path}/b.md').writeAsStringSync('rujuk [[a]] dan [[hantu]]\n');
  });

  tearDown(() => vault.delete(recursive: true));

  Future<NoteEditor> loadedEditor(String path) async {
    final notes = await VaultScanner.scan(vault.path);
    final editor = NoteEditor(
      vaultDir: vault.path,
      resolver: VaultLinkResolver(notes),
    );
    await editor.load(path);
    return editor;
  }

  Future<void> pumpEditor(WidgetTester tester, NoteEditor editor) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SimpulNoteEditorPage(
          vault: vault.path,
          initialPath: editor.path,
          initialEditor: editor,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  test('open, edit, undo/redo, simpan atomik (alur penuh)', () async {
    final editor = await loadedEditor('a.md');
    expect(editor.dirty, isFalse);
    editor.text = '# Judul A\n\nisi baru\n';
    expect(editor.dirty, isTrue);
    editor.undo();
    expect(editor.text, '# Judul A\n\nisi **tebal** `kode`\n');
    editor.redo();
    await editor.save();
    expect(editor.dirty, isFalse);
    expect(
      File('${vault.path}/a.md').readAsStringSync(),
      '# Judul A\n\nisi baru\n',
    );
    expect(
      Directory(vault.path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('backlink dan tautan rusak untuk b.md', () async {
    final editor = await loadedEditor('b.md');
    expect(editor.backlinks(), isEmpty);
    final links = editor.links();
    final resolved = links.where((l) => l.resolved).toList();
    final broken = links.where((l) => !l.resolved).toList();
    expect(resolved.single.resolvedPath, 'a.md');
    expect(broken.single.link.target, 'hantu');
  });

  testWidgets('render editor, edit, simpan atomik', (tester) async {
    final editor = await tester.runAsync(() => loadedEditor('a.md'));
    await pumpEditor(tester, editor!);

    expect(find.text('a.md'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'isi baru\n');
    await tester.pump();
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);

    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is CircleAvatar && w.backgroundColor == Colors.orangeAccent),
      findsOneWidget,
    );
  });

  testWidgets('undo mengembalikan teks sebelum edit', (tester) async {
    final editor = await tester.runAsync(() => loadedEditor('a.md'));
    await pumpEditor(tester, editor!);

    await tester.enterText(find.byType(TextField).last, 'diganti\n');
    await tester.pump();
    await tester.tap(find.byTooltip('Undo (FR-16)'));
    await tester.pump();

    expect(find.widgetWithText(TextField, '# Judul A\n\nisi **tebal** `kode`\n'),
        findsOneWidget);
  });

  testWidgets('pratinjau merender heading dan bold', (tester) async {
    final editor = await tester.runAsync(() => loadedEditor('a.md'));
    await pumpEditor(tester, editor!);

    await tester.tap(find.byTooltip('Pratinjau (FR-10)'));
    await tester.pumpAndSettle();

    expect(find.text('Judul A'), findsOneWidget);
    expect(find.textContaining('tebal', findRichText: true), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('panel tautan: backlink dan tautan rusak', (tester) async {
    final editor = await tester.runAsync(() => loadedEditor('b.md'));
    await pumpEditor(tester, editor!);

    expect(find.textContaining('0 backlink, 2 keluar, 1 rusak'), findsOneWidget);

    await tester.tap(find.textContaining('Tautan (FR-20/21)'));
    await tester.pumpAndSettle();

    expect(find.text('a.md'), findsOneWidget);
    expect(find.text('hantu'), findsOneWidget);
  });
}
