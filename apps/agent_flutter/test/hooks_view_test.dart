import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/hooks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// SETTINGS-HOOKS (Codex item 1): halaman GUI Hooks — daftar hook aktif,
/// statistik sukses/gagal, form add/edit, delete, dan test fire.
void main() {
  final snapshot = HooksSnapshot(
    rules: [
      HookRuleInfo(
        event: 'model.switched',
        webhookUrl: 'https://contoh.io/hook',
        timeoutSec: 30,
      ),
      HookRuleInfo(
        event: 'session.*',
        script: 'scripts/notify.sh',
        timeoutSec: 12,
        env: {'API_KEY': 'xyz'},
      ),
    ],
    stats: {
      'hooks[0]:webhook': HookStatInfo(
        fires: 3,
        failures: 1,
        lastError: 'timeout',
        lastAt: '2026-02-11T00:00:00.000Z',
      ),
    },
  );

  Widget host(HooksPage page) => MaterialApp(home: Scaffold(body: page));

  testWidgets('halaman kosong menampilkan empty state', (tester) async {
    await tester.pumpWidget(host(HooksPage(
      snapshot: HooksSnapshot(),
      online: true,
      loading: false,
      onAdd: (_) async {},
      onRefresh: null,
    )));
    expect(find.text('Belum ada hook terpasang.'), findsOneWidget);
  });

  testWidgets('render kartu hook + statistik fire/gagal', (tester) async {
    await tester.pumpWidget(host(HooksPage(
      snapshot: snapshot,
      online: true,
      loading: false,
    )));
    expect(find.byKey(const Key('hook-card-0')), findsOneWidget);
    expect(find.byKey(const Key('hook-card-1')), findsOneWidget);
    expect(find.text('model.switched'), findsOneWidget);
    expect(find.text('session.*'), findsOneWidget);
    expect(find.text('fire: 3'), findsOneWidget);
    expect(find.text('gagal: 1'), findsOneWidget);
    expect(find.text('belum pernah fire'), findsOneWidget);
  });

  testWidgets('tombol add membuka form dan submit memanggil onAdd',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final payloads = <Map<String, dynamic>>[];
    await tester.pumpWidget(host(HooksPage(
      snapshot: snapshot,
      online: true,
      loading: false,
      onAdd: (body) async => payloads.add(body),
    )));
    await tester.tap(find.byKey(const Key('hooks-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('hook-form-event')), 'turn.*');
    await tester.enterText(
        find.byKey(const Key('hook-form-target')), 'https://x.io/h');
    await tester.enterText(
        find.byKey(const Key('hook-form-timeout')), '20');
    await tester.tap(find.byKey(const Key('hook-form-save')));
    await tester.pumpAndSettle();
    expect(payloads.single, {
      'event': 'turn.*',
      'webhook': 'https://x.io/h',
      'timeout_sec': 20,
    });
  });

  testWidgets('switch ke script mengirim field script, bukan webhook',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final payloads = <Map<String, dynamic>>[];
    await tester.pumpWidget(host(HooksPage(
      snapshot: snapshot,
      online: true,
      loading: false,
      onAdd: (body) async => payloads.add(body),
    )));
    await tester.tap(find.byKey(const Key('hooks-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Script'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('hook-form-event')), 'turn.*');
    await tester.enterText(
        find.byKey(const Key('hook-form-target')), 'scripts/run.sh');
    await tester.enterText(
        find.byKey(const Key('hook-form-env')), 'A=1\nBAD_LINE\n');
    await tester.tap(find.byKey(const Key('hook-form-save')));
    await tester.pump();
    expect(find.text('Env harus format KEY=VALUE per baris'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('hook-form-env')), 'A=1\n');
    await tester.tap(find.byKey(const Key('hook-form-save')));
    await tester.pumpAndSettle();
    expect(payloads.single, {
      'event': 'turn.*',
      'script': 'scripts/run.sh',
      'timeout_sec': 30,
      'env': {'A': '1'},
    });
  });

  testWidgets('test hook memanggil onTest dan menampilkan hasil gagal',
      (tester) async {
    await tester.pumpWidget(host(HooksPage(
      snapshot: snapshot,
      online: true,
      loading: false,
      onTest: (index) async => {
        'index': index,
        'results': [
          {'target': 'webhook', 'ok': false, 'error': 'ECONNREFUSED'},
        ],
      },
    )));
    await tester.tap(find.byKey(const Key('hook-test-0')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('ECONNREFUSED'), findsOneWidget);
  });

  testWidgets('hapus hook memakai dialog konfirmasi', (tester) async {
    final deleted = <int>[];
    await tester.pumpWidget(host(HooksPage(
      snapshot: snapshot,
      online: true,
      loading: false,
      onDelete: (index) async => deleted.add(index),
    )));
    await tester.tap(find.byKey(const Key('hook-delete-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Hapus'));
    await tester.pumpAndSettle();
    expect(deleted, [1]);
  });
}
