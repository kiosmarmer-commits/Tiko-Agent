import 'package:agent_flutter/ui/settings_store.dart';
import 'package:agent_flutter/ui/settings_view.dart';
import 'package:agent_flutter/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('AppSettings roundtrip menyimpan tema, aksen, dan perilaku', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings(
      themeMode: ThemeMode.light,
      accent: AppSettings.accents[2],
      ollamaHost: 'http://ollama:11434',
      vaultPath: '/vault',
      autoLockMinutes: 15,
    );
    await settings.save();

    final loaded = await AppSettings.load();
    expect(loaded.themeMode, ThemeMode.light);
    expect(loaded.accent.toARGB32(), AppSettings.accents[2].toARGB32());
    expect(loaded.ollamaHost, 'http://ollama:11434');
    expect(loaded.vaultPath, '/vault');
    expect(loaded.autoLockMinutes, 15);
  });

  test('GUI-P0-05: AppSettings tidak menyimpan bearer token ke preferences', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings(
      themeMode: ThemeMode.light,
      accent: AppSettings.accents[1],
      vaultPath: '/vault',
    ).save();

    final prefs = await SharedPreferences.getInstance();
    final secretLike = prefs.getKeys().where(
      (key) => key.toLowerCase().contains('token') || key.toLowerCase().contains('secret'),
    );
    expect(secretLike, isEmpty);
  });

  test('AppSettings default: dark, aksen default, auto-lock mati', () async {
    SharedPreferences.setMockInitialValues({});
    final loaded = await AppSettings.load();
    expect(loaded.themeMode, ThemeMode.dark);
    expect(loaded.accent.toARGB32(), SimpulTheme.accent.toARGB32());
    expect(loaded.autoLockMinutes, 0);
  });

  test('SimpulTheme.theme menghasilkan brightness dan aksen yang diminta', () {
    final dark = SimpulTheme.theme(Brightness.dark, AppSettings.accents[1]);
    expect(dark.brightness, Brightness.dark);
    expect(dark.colorScheme.primary.toARGB32(), AppSettings.accents[1].toARGB32());
    final light = SimpulTheme.theme(Brightness.light, SimpulTheme.accent);
    expect(light.scaffoldBackgroundColor, SimpulTheme.bgLight);
  });

  testWidgets('SettingsView merender tiga seksi dan merespons perubahan tema',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var latest = AppSettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: latest,
            baseUrl: 'http://127.0.0.1:8787',
            token: 'tok',
            online: false,
            onConnect: ({required base, required tok}) {},
            onSettingsChanged: (next) => latest = next,
          ),
        ),
      ),
    );
    expect(find.text('Tampilan'), findsOneWidget);
    expect(find.text('Koneksi'), findsOneWidget);
    expect(find.text('Perilaku'), findsOneWidget);

    await tester.tap(find.text('Terang'));
    await tester.pump();
    expect(latest.themeMode, ThemeMode.light);
  });

  testWidgets('GUI-P1-08: scope terpisah — caption perangkat/kredensial/daemon',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: AppSettings(),
            baseUrl: 'http://127.0.0.1:8787',
            token: 'tok',
            online: false,
            onConnect: ({required base, required tok}) {},
            onSettingsChanged: (_) {},
            daemonStatus: {
              'ok': true,
              'version': '1.2.3',
              'provider': 'mock-1',
              'memory': 'sqlite',
              'safe_mode': true,
              'sandbox': 'process',
              'resource_profile': 'laptop',
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Perangkat'), findsWidgets);
    expect(find.textContaining('Kredensial'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('Versi'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Konfigurasi daemon'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pump();

    expect(find.text('Konfigurasi daemon'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();

    expect(find.textContaining('read-only'), findsWidgets);
    expect(find.text('Daemon \u2014 status runtime'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('mock-1'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
    expect(find.textContaining('Config immutable'), findsOneWidget);
  });

  testWidgets('GUI-P1-08: toggle visibilitas bearer token', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: AppSettings(),
            baseUrl: 'http://127.0.0.1:8787',
            token: 'secret-token-123',
            online: false,
            onConnect: ({required base, required tok}) {},
            onSettingsChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();

    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.text('secret-token-123'), findsOneWidget);
  });
}
