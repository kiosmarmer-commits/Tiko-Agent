import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_flutter/main.dart';
import 'package:agent_flutter/ui/settings_store.dart';

void main() {
  testWidgets('Agent app renders its main navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
        initialSettings: AppSettings(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Layout sempit default (800x600) memakai NavigationBar bawah.
    // Label domain sama dengan desktop (GUI-P0-01): satu route map.
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Approvals'), findsOneWidget);
    expect(find.text('Runs'), findsOneWidget);
    expect(find.text('Sessions'), findsNothing);
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Pesan ke Tiko…'), findsOneWidget);
  });

  testWidgets('Agent app uses NavigationRail on wide screens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
        initialSettings: AppSettings(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('More tools'), findsOneWidget);
    await tester.tap(find.text('More tools'));
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
  });
}
