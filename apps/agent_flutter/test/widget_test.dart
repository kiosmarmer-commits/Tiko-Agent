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
    await tester.pump();

    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Memori'), findsOneWidget);
  });
}
