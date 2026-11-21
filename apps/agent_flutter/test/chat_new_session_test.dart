import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_flutter/main.dart';
import 'package:agent_flutter/ui/settings_store.dart';

void main() {
  testWidgets('GUI-P3: tombol chat baru mengganti sesi aktif dan bersihkan chat',
      (tester) async {
    await tester.pumpWidget(
      AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
        initialSettings: AppSettings(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('btn-chat-new-session')), findsOneWidget);
    expect(find.byKey(const Key('btn-chat-provider-picker')), findsNothing);
    expect(find.text('flutter:default'), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-chat-new-session')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('flutter:default'), findsNothing);
    expect(find.textContaining('flutter:chat-'), findsOneWidget);
  });
}
