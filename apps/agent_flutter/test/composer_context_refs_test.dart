import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_flutter/main.dart';
import 'package:agent_flutter/ui/settings_store.dart';

/// SETTINGS-CONTEXT-REFS (Codex item 2): chip visual & autocomplete token
/// `@file`/`@dir`/`@url`/`@git` di composer via [AgentApp] (builtin saran
/// tidak butuh backend).
void main() {
  testWidgets('ketik @fi menampilkan saran builtin dan tap menyisipkan token',
      (tester) async {
    await tester.pumpWidget(AgentApp(
      initialBaseUrl: 'http://localhost:8787',
      initialToken: 'test-token',
      initialSettings: AppSettings(),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), '@fi');
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const Key('chip-suggest-builtin-@file:')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('chip-suggest-builtin-@file:')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.widgetWithText(TextField, '@file:'), findsOneWidget);
  });

  testWidgets('token lengkap tampil sebagai chip visual dan bisa dihapus',
      (tester) async {
    await tester.pumpWidget(AgentApp(
      initialBaseUrl: 'http://localhost:8787',
      initialToken: 'test-token',
      initialSettings: AppSettings(),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
        find.byType(TextField), 'cek @file:src/main.dart dan @git:diff');
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const Key('chip-context-ref-0')),
      findsOneWidget,
    );
    expect(find.text('@file:src/main.dart'), findsOneWidget);
    expect(find.text('@git:diff'), findsNWidgets(2));

    await tester.tap(find.descendant(
      of: find.byKey(const Key('chip-context-ref-1')),
      matching: find.byType(Icon),
    ).last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('chip-context-ref-1')), findsNothing);
    expect(find.text('@git:diff'), findsNothing);
    expect(find.text('@file:src/main.dart'), findsOneWidget);
  });
}
