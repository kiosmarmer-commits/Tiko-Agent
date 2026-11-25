import 'package:agent_flutter/ui/global_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ctrl+K, Ctrl+N, Ctrl+H, Ctrl+Alt+ArrowUP/Down memicu callback', (
    tester,
  ) async {
    var palette = 0;
    var newChat = 0;
    var history = 0;
    var prev = 0;
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GlobalShortcuts(
          onPalette: () => palette++,
          onNewChat: () => newChat++,
          onOpenHistory: () => history++,
          onPreviousSession: () => prev++,
          onNextSession: () => next++,
          child: const Scaffold(body: Text('hai')),
        ),
      ),
    );

    Future<void> press(List<LogicalKeyboardKey> keys) async {
      for (final key in keys) {
        await tester.sendKeyDownEvent(key);
      }
      await tester.pump();
      for (final key in keys.reversed) {
        await tester.sendKeyUpEvent(key);
      }
      await tester.pump();
    }

    await press([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyK]);
    expect(palette, 1);
    await press([LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyP]);
    expect(palette, 2);
    await press([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyN]);
    expect(newChat, 1);
    await press([LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyH]);
    expect(history, 1);
    await press([
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.arrowUp,
    ]);
    expect(prev, 1);
    await press([
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.arrowDown,
    ]);
    expect(next, 1);
  });

  testWidgets(
    'binding null tidak dipasang: Ctrl+N tanpa callback tidak throw',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GlobalShortcuts(
            onPalette: () {},
            child: const Scaffold(body: TextField()),
          ),
        ),
      );
      final focus = Focus.of(tester.element(find.byType(TextField).first));
      focus.requestFocus();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Esc global memicu onEscape (tutup panel terbuka)', (
    tester,
  ) async {
    var escaped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GlobalShortcuts(
          onPalette: () {},
          onEscape: () => escaped++,
          child: const Scaffold(body: TextField()),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'x');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(escaped, 1);
  });
}
