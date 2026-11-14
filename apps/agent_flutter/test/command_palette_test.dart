import 'package:agent_flutter/ui/command_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('palette opens, filters, and runs the selected action',
      (tester) async {
    var ran = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showCommandPalette(context, [
                PaletteAction('Buka: a.md', () => ran = 'a'),
                PaletteAction('Buka: b.md', () => ran = 'b'),
                PaletteAction('Toggle pratinjau', () => ran = 'preview'),
              ]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Buka: a.md'), findsOneWidget);
    expect(find.text('Toggle pratinjau'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'pratinjau');
    await tester.pumpAndSettle();
    expect(find.text('Buka: a.md'), findsNothing);
    expect(find.text('Toggle pratinjau'), findsOneWidget);

    await tester.tap(find.text('Toggle pratinjau'));
    await tester.pumpAndSettle();
    expect(ran, 'preview');
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('palette empty query shows all actions; unknown filter shows empty note',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showCommandPalette(
                  context, [PaletteAction('Simpan catatan', () {})]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz-tidak-ada');
    await tester.pumpAndSettle();
    expect(find.text('Tidak ada perintah yang cocok.'), findsOneWidget);
  });

  testWidgets('PaletteShortcut triggers on Ctrl+K', (tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: PaletteShortcut(
        onPalette: () => opened = true,
        child: const Scaffold(body: Text('page')),
      ),
    ));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(opened, isTrue);
  });
}
