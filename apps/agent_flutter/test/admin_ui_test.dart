import 'package:agent_flutter/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// P1-07: do not reference library-private page widgets.
void main() {
  group('Admin UI via AgentApp', () {
    testWidgets('AgentApp builds', (tester) async {
      await tester.pumpWidget(
        const AgentApp(
          initialBaseUrl: 'http://localhost:8787',
          initialToken: 'test-token',
        ),
      );
      await tester.pump();
      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('no exception on pump', (tester) async {
      await tester.pumpWidget(
        const AgentApp(
          initialBaseUrl: 'http://localhost:8787',
          initialToken: 'test-token',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
