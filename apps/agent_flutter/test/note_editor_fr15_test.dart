import 'dart:io';

import 'package:agent_flutter/ui/note_chat_panel.dart';
import 'package:agent_flutter/ui/note_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpul_core/simpul_core.dart';

void main() {
  group('editor tabs (FR-15)', () {
    testWidgets('tab bar lists open notes and switches on tap',
        (tester) async {
      final dir = (await tester.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('simpul_tabs_');
        await File('${d.path}/a.md').writeAsString('Isi A');
        await File('${d.path}/b.md').writeAsString('Isi B');
        return d;
      }))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = NoteEditor(vaultDir: dir.path);
      final b = NoteEditor(vaultDir: dir.path);
      await tester.runAsync(() async {
        await a.load('a.md');
        await b.load('b.md');
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteEditorPage(vault: dir.path, initialTabs: [a, b]),
        ),
      ));
      expect(find.text('a.md'), findsOneWidget);
      expect(find.text('b.md'), findsNWidgets(2));
      expect(find.widgetWithText(TextField, 'Isi B'), findsOneWidget);

      await tester.tap(find.text('a.md'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Isi A'), findsOneWidget);
    });

    testWidgets('dirty tab shows marker; closing clean tab keeps dirty one',
        (tester) async {
      final dir = (await tester.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('simpul_tabs2_');
        await File('${d.path}/a.md').writeAsString('Isi A');
        await File('${d.path}/b.md').writeAsString('Isi B');
        return d;
      }))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = NoteEditor(vaultDir: dir.path);
      final b = NoteEditor(vaultDir: dir.path);
      await tester.runAsync(() async {
        await a.load('a.md');
        await b.load('b.md');
      });
      a.text = 'diubah';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteEditorPage(vault: dir.path, initialTabs: [a, b]),
        ),
      ));
      expect(
        find.byWidgetPredicate(
            (w) => w is CircleAvatar && w.radius == 3),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(find.text('b.md'), findsNothing);
      expect(find.widgetWithText(TextField, 'diubah'), findsOneWidget);
    });
  });

  group('split view and focus mode (FR-15)', () {
    testWidgets('split shows live preview beside the editor', (tester) async {
      final editor = NoteEditor(vaultDir: '/tmp')..text = '# Judul\n\nIsi.';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteEditorPage(vault: '/tmp', initialEditor: editor),
        ),
      ));
      expect(find.byType(MarkdownPreview), findsNothing);
      await tester.tap(find.byIcon(Icons.splitscreen));
      await tester.pump();
      expect(find.byType(MarkdownPreview), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
    });

    testWidgets('focus mode hides vault/path row', (tester) async {
      final editor = NoteEditor(vaultDir: '/tmp')..text = 'isi';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteEditorPage(vault: '/tmp', initialEditor: editor),
        ),
      ));
      expect(find.text('Buka'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pump();
      expect(find.text('Buka'), findsNothing);
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pump();
      expect(find.text('Buka'), findsOneWidget);
    });
  });

  group('resource stats badge (AI-U03)', () {
    testWidgets('periodic poll updates CPU percent from tick deltas',
        (tester) async {
      var ticks = 100;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SimpulNoteChatPanel(
            vault: '/nonexistent-vault',
            notePath: 'ai.md',
            resourceStats: true,
            snapshotOverride: () => ResourceSnapshot(
              rssMb: 120.0,
              cpuCount: 4,
              loadAvg1: null,
              cpuTicks: ticks += 200,
            ),
            onInsert: (_) {},
          ),
        ),
      ));
      expect(find.textContaining('RAM ~120 MB'), findsOneWidget);
      expect(find.textContaining('CPU'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('CPU ~100%'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
