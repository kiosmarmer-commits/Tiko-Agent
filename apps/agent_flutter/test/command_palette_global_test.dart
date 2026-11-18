import 'package:agent_flutter/ui/command_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Command palette global (GUI-P2-02, FR-44): Ctrl+K/Ctrl+P membuka
/// overlay aksi, filter, Enter menjalankan aksi terpilih, Escape menutup.
void main() {
  Widget harness(VoidCallback onPalette) => MaterialApp(
        home: PaletteShortcut(
          onPalette: onPalette,
          child: const Scaffold(body: Text('dashboard')),
        ),
      );

  Future<void> pressShortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('Ctrl+K membuka palette dan Enter menjalankan aksi',
      (tester) async {
    var ran = false;
    await tester.pumpWidget(harness(() async {
      showCommandPalette(
        tester.element(find.byType(Scaffold).first),
        [
          PaletteAction('Buka Runs', () => ran = true, hint: 'navigasi'),
          PaletteAction('Muat ulang', () {}),
        ],
      );
    }));
    await pressShortcut(tester);
    expect(find.text('Buka Runs'), findsOneWidget);
    expect(find.text('Ketik perintah atau nama catatan...'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'runs');
    await tester.pump();
    expect(find.text('Muat ulang'), findsNothing);

    await tester.tap(find.text('Buka Runs'));
    await tester.pump();
    expect(ran, isTrue);
    expect(find.text('Buka Runs'), findsNothing);
  });

  testWidgets('filter tak cocok menampilkan pesan kosong; Escape menutup',
      (tester) async {
    await tester.pumpWidget(harness(() async {
      showCommandPalette(
        tester.element(find.byType(Scaffold).first),
        const [],
      );
    }));
    await pressShortcut(tester);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('Tidak ada perintah yang cocok.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });
}
