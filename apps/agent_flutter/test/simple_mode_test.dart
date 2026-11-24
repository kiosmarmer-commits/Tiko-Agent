import 'package:agent_flutter/app/app_routes.dart';
import 'package:agent_flutter/shell/desktop_shell.dart';
import 'package:agent_flutter/shell/mobile_shell.dart';
import 'package:agent_flutter/ui/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('GUI-P2-01: visibleRoutes memfilter modul teknis pada Simple mode', () {
    final advanced = visibleRoutes(advanced: true);
    final simple = visibleRoutes(advanced: false);

    expect(advanced, kAppRoutes);
    expect(simple.map((e) => e.route).toSet(), kSimpleRoutes);
    expect(kSimpleRoutes.contains(AppRoute.chat), isTrue);
    expect(kSimpleRoutes.contains(AppRoute.approvals), isTrue);
    expect(kSimpleRoutes.contains(AppRoute.memory), isTrue);
    expect(kSimpleRoutes.contains(AppRoute.tasks), isTrue);
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.providers)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.skills)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.bots)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.plugins)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.channels)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.automations)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.security)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.automations)));
    expect(simple.map((e) => e.route), isNot(contains(AppRoute.audit)));
  });

  test('GUI-P2-01: AppSettings menyimpan mode Advanced', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings(advancedMode: false).save();
    final loaded = await AppSettings.load();
    expect(loaded.advancedMode, isFalse);

    await loaded.copyWith(advancedMode: true).save();
    expect((await AppSettings.load()).advancedMode, isTrue);
  });

  testWidgets(
    'GUI-P2-01: DesktopShell Simple mode hanya menampilkan route inti',
    (tester) async {
      final simple = visibleRoutes(advanced: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopShell(
              selected: AppRoute.chat,
              onSelect: (_) {},
              entries: simple,
              child: const SizedBox(),
            ),
          ),
        ),
      );

      for (final label in ['Chat', 'Home', 'Approvals', 'More tools']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.text('More tools'));
      await tester.pump();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Providers'), findsNothing);
      expect(find.text('Bots'), findsNothing);
      expect(find.text('Skills'), findsNothing);
    },
  );

  testWidgets(
    'GUI-P2-01: MobileShell Simple mode tidak mengubah bottom bar inti',
    (tester) async {
      final simple = visibleRoutes(advanced: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileShell(
              selected: AppRoute.chat,
              onSelect: (_) {},
              entries: simple,
              child: const SizedBox(),
            ),
          ),
        ),
      );

      expect(find.text('More'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );
}
