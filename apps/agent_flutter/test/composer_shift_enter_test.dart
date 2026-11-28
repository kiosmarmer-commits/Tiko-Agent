import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_flutter/main.dart';
import 'package:agent_flutter/ui/settings_store.dart';

/// Composer multi-baris: Shift+Enter menyisipkan newline tanpa mengirim;
/// Enter polos tetap submit ( perilaku standar chat modern).
void main() {
  testWidgets('Shift+Enter menyisipkan newline dan tidak mengirim',
      (tester) async {
    await tester.pumpWidget(AgentApp(
      initialBaseUrl: 'http://localhost:8787',
      initialToken: 'test-token',
      initialSettings: AppSettings(),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'baris pertama');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 50));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'baris pertama\n');
  });

  testWidgets('Enter polos tetap submit', (tester) async {
    await tester.pumpWidget(AgentApp(
      initialBaseUrl: 'http://localhost:8787',
      initialToken: 'test-token',
      initialSettings: AppSettings(),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'cek');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));

    // Turn mulai: bubble user + placeholder assistant muncul di chat.
    expect(find.text('cek'), findsWidgets);
  });
}
