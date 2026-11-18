import 'package:agent_flutter/app/app_routes.dart';
import 'package:agent_flutter/shell/desktop_shell.dart';
import 'package:agent_flutter/shell/mobile_shell.dart';
import 'package:agent_flutter/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GUI-P0-01: route map tunggal', () {
    test('setiap route punya label, ikon, dan tidak ada duplikat', () {
      final routes = kAppRoutes.map((e) => e.route).toSet();
      expect(routes.length, kAppRoutes.length);
      expect(routes, containsAll(AppRoute.values));
      for (final entry in kAppRoutes) {
        expect(entry.label, isNotEmpty);
        expect(entry.route.label, entry.label);
      }
      expect(kAppRoutes.first.route, AppRoute.chat);
    });

    test('label domain sama lintas platform: route admin dikelompokkan di More', () {
      final primary = kMobilePrimaryRoutes;
      expect(primary.length, 4);
      expect(primary.map((e) => e.route),
          [AppRoute.chat, AppRoute.dashboard, AppRoute.approvals, AppRoute.sessions]);
      final grouped = kAppRoutes
          .where((e) => !e.primaryOnMobile)
          .map((e) => e.route)
          .toSet();
      expect(
          grouped,
          {AppRoute.tasks, AppRoute.skills, AppRoute.bots, AppRoute.providers,
              AppRoute.plugins, AppRoute.channels, AppRoute.automations,
              AppRoute.security, AppRoute.memory, AppRoute.events,
              AppRoute.logs, AppRoute.settings});
    });
  });

  group('GUI-P0-01: DesktopShell dari route map', () {
    testWidgets('rail menampilkan semua route dengan label bersama',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DesktopShell(
            selected: AppRoute.chat,
            onSelect: (_) {},
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(NavigationRail), findsOneWidget);
      for (final entry in kAppRoutes) {
        expect(find.text(entry.label), findsOneWidget);
      }
    });

    testWidgets('tap destinasi memanggil onSelect dengan route yang tepat',
        (tester) async {
      AppRoute? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DesktopShell(
            selected: AppRoute.chat,
            onSelect: (r) => picked = r,
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('Approvals'));
      await tester.pump();
      expect(picked, AppRoute.approvals);
    });

    testWidgets('GUI-P0-06: badge approval pending tampil saat > 0',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DesktopShell(
            selected: AppRoute.chat,
            onSelect: (_) {},
            pendingApprovals: 3,
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(Badge), findsOneWidget);
      expect(find.descendant(
        of: find.byType(Badge),
        matching: find.text('3'),
      ), findsOneWidget);
    });

    testWidgets('GUI-P0-06: tanpa pending, badge tidak tampil',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DesktopShell(
            selected: AppRoute.chat,
            onSelect: (_) {},
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(Badge), findsNothing);
    });
  });

  group('GUI-P0-01: MobileShell dari route map', () {
    testWidgets('bottom bar menampilkan route primer + More', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MobileShell(
            selected: AppRoute.chat,
            onSelect: (_) {},
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(NavigationBar), findsOneWidget);
      for (final entry in kMobilePrimaryRoutes) {
        expect(find.text(entry.label), findsOneWidget);
      }
      expect(find.text(kMobileMoreLabel), findsOneWidget);
      expect(find.text('Memory'), findsNothing);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('tap More mengirim null, tap Chat mengirim route',
        (tester) async {
      AppRoute? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MobileShell(
            selected: null,
            onSelect: (r) => picked = r,
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text(kMobileMoreLabel));
      await tester.pump();
      expect(picked, isNull);

      await tester.tap(find.text('Chat'));
      await tester.pump();
      expect(picked, AppRoute.chat);
    });

    testWidgets('GUI-P0-06: badge approval pending tampil di bottom bar',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MobileShell(
            selected: AppRoute.chat,
            onSelect: (_) {},
            pendingApprovals: 2,
            child: const SizedBox(),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(Badge), findsOneWidget);
      expect(find.descendant(
        of: find.byType(Badge),
        matching: find.text('2'),
      ), findsOneWidget);
    });
  });

  group('GUI-P0-01: design tokens', () {
    test('token permukaan & status punya varian dark/light berbeda', () {
          expect(SimpulTheme.raised(Brightness.dark),
              isNot(SimpulTheme.raised(Brightness.light)));
          expect(SimpulTheme.hover(Brightness.dark),
              isNot(SimpulTheme.hover(Brightness.light)));
          expect(SimpulTheme.selected(Brightness.dark),
              isNot(SimpulTheme.selected(Brightness.light)));
          expect(SimpulTheme.successColor(Brightness.dark),
              isNot(SimpulTheme.successColor(Brightness.light)));
          expect(SimpulTheme.infoColor(Brightness.dark),
              isNot(SimpulTheme.infoColor(Brightness.light)));
    });
    test('skala spacing, radius, dan tipografi tersedia', () {
          expect(SimpulTheme.xxxl, 32.0);
          expect(SimpulTheme.radiusSmall, 8.0);
          expect(SimpulTheme.radiusLarge, 16.0);
          expect(SimpulTheme.display.fontSize, 28);
          expect(SimpulTheme.pageTitle.fontSize, 22);
          expect(SimpulTheme.sectionTitle.fontSize, 16);
          expect(SimpulTheme.body.fontSize, 14);
          expect(SimpulTheme.caption.fontSize, 12);
    });
  });
}
