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
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Approvals'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Chat history'), findsNothing);
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Pesan ke Tiko…'), findsOneWidget);
  });

  testWidgets('Agent app uses the desktop sidebar on wide screens', (
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
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    await tester.tap(find.text('Explore'));
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
  });
}
