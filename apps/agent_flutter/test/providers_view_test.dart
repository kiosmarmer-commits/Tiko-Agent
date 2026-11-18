import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/provider_manager_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ProviderManagerPage page) => MaterialApp(home: Scaffold(body: page));

const _snapshot = ProvidersSnapshot(
  defaultId: 'mock-1',
  providers: [
    ProviderItem(
      id: 'mock-1',
      toolCalling: true,
      vision: false,
      streaming: true,
      maxContext: 8192,
      health: ProviderHealthInfo(
        failures: 0,
        successes: 9,
        open: false,
        phase: 'closed',
        lastLatencyMs: 12.5,
      ),
    ),
    ProviderItem(
      id: 'mock-2',
      health: ProviderHealthInfo(
        failures: 4,
        successes: 1,
        open: true,
        phase: 'open',
        lastError: 'koneksi gagal',
      ),
    ),
  ],
  tiers: {'1': 'mock-1', '3': 'mock-2'},
  sessionOverrides: {'ws:lab': 'mock-2'},
);

void main() {
  testWidgets('menampilkan provider, chip health, tier, dan override',
      (tester) async {
    await tester.pumpWidget(_wrap(const ProviderManagerPage(
      snapshot: _snapshot,
      availableSessions: ['ws:lab'],
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('mock-1'), findsOneWidget);
    expect(find.text('mock-2'), findsOneWidget);
    expect(find.text('closed'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(find.textContaining('tier 1 → mock-1'), findsOneWidget);
    expect(find.text('override → mock-2'), findsOneWidget);
    expect(find.text('koneksi gagal'), findsOneWidget);
  });

  testWidgets('kondisi kosong: snapshot null menampilkan pesan',
      (tester) async {
    await tester.pumpWidget(_wrap(const ProviderManagerPage(
      snapshot: null,
      availableSessions: [],
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Belum ada data provider.'), findsOneWidget);
  });

  testWidgets('tombol refresh memanggil onRefresh', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(_wrap(ProviderManagerPage(
      snapshot: _snapshot,
      availableSessions: const [],
      online: true,
      loading: false,
      onRefresh: () async => refreshed++,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(refreshed, 1);
  });

  testWidgets('dialog override: session id + provider default terkirim',
      (tester) async {
    var setWith = '';
    await tester.pumpWidget(_wrap(ProviderManagerPage(
      snapshot: _snapshot,
      availableSessions: const ['ws:baru'],
      online: true,
      loading: false,
      onSetSessionProvider: (sessionId, providerArg) async {
        setWith = '$sessionId:$providerArg';
        return true;
      },
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Set override sesi'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Session id'), 'ws:baru');
    await tester.tap(find.text('Simpan'));
    await tester.pumpAndSettle();

    expect(setWith, 'ws:baru:mock-1');
    expect(find.textContaining('Sesi ws:baru memakai provider'),
        findsOneWidget);
  });

  testWidgets('reset default pada override memanggil callback',
      (tester) async {
    var resetFor = '';
    await tester.pumpWidget(_wrap(ProviderManagerPage(
      snapshot: _snapshot,
      availableSessions: const [],
      online: true,
      loading: false,
      onSetSessionProvider: (sessionId, providerArg) async {
        resetFor = '$sessionId:$providerArg';
        return true;
      },
    )));
    await tester.pump();

    await tester.tap(find.text('Reset default'));
    await tester.pumpAndSettle();

    expect(resetFor, 'ws:lab:default');
  });
}
