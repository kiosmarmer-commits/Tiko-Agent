import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_flutter/main.dart';

void main() {
  testWidgets('Agent app renders its main navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Layout sempit default (800x600) memakai NavigationBar bawah.
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
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
      const AgentApp(
        initialBaseUrl: 'http://localhost:8787',
        initialToken: 'test-token',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
