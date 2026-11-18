import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/security_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(SecurityPage page) => MaterialApp(home: Scaffold(body: page));

const _snapshot = SecuritySnapshot(
  safeMode: true,
  panic: false,
  stopRequested: false,
  sandbox: 'landlock',
  sealedStorage: true,
  plugins: [
    SecurityPluginItem(
        id: 'weather',
        registered: true,
        grantedCount: 3,
        requestedCount: 3),
    SecurityPluginItem(
        id: 'database',
        registered: true,
        pending: true,
        grantedCount: 0,
        requestedCount: 2),
  ],
  tokenAnomalyEnabled: true,
  quarantinesToday: 1,
  maxQuarantinesPerDay: 5,
  tokenSkillStats: [
    SkillTokenStat(slug: 'berita', samples: 42),
    SkillTokenStat(slug: 'ringkas', samples: 18),
  ],
  rateWindowSec: 60,
  rateMaxEvents: 40,
  guardBlockedTurns: 2,
  guardSanitizedTurns: 7,
  auditTotal: 320,
  auditRecent: [
    {
      'ts': '2026-11-18T13:00:00.000Z',
      'tool': 'shell.exec',
      'risk': 'high',
      'verdict': 'allowed',
      'session': 's-1',
    },
  ],
  activeSessions: 2,
);

void main() {
  testWidgets('menampilkan kartu safety lengkap: pills dan sesi aktif',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Safety'), findsOneWidget);
    expect(find.text('safe mode ON'), findsOneWidget);
    expect(find.textContaining('sandbox landlock'), findsOneWidget);
    expect(find.text('kredensial terenkripsi at-rest'), findsOneWidget);
    expect(find.text('Sesi aktif: 2'), findsOneWidget);
    expect(find.text('Plugin & consent'), findsOneWidget);
    expect(find.text('menunggu consent'), findsOneWidget);
  });

  testWidgets('status panic menampilkan pill PANIC dan border merah',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: SecuritySnapshot(panic: true, activeSessions: 1),
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('PANIC aktif'), findsOneWidget);
    expect(find.textContaining('PANIC'), findsAtLeastNWidgets(2));
  });

  testWidgets('token anomaly off: menampilkan pesan detektor nonaktif',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: SecuritySnapshot(tokenAnomalyEnabled: false),
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.textContaining('Detektor nonaktif'), findsOneWidget);
    expect(find.textContaining('berita: 42 sampel'), findsNothing);
  });

  testWidgets('token anomaly aktif: kuota karantina dan baseline skill',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.textContaining('karantina hari ini 1/5'), findsOneWidget);
    expect(find.textContaining('berita: 42 sampel baseline'), findsOneWidget);
    expect(find.textContaining('ringkas: 18 sampel baseline'), findsOneWidget);
  });

  testWidgets('plugin kosong dan audit kosong: pesan kondisi kosong',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: SecuritySnapshot(auditTotal: 0),
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Tidak ada plugin terdaftar.'), findsOneWidget);
    expect(find.textContaining('Audit terakhir (0 entri'), findsOneWidget);
    expect(find.text('Belum ada entri audit.'), findsOneWidget);
  });

  testWidgets('entri audit tampil dengan tool, risk, verdict, session',
      (tester) async {
    await tester.pumpWidget(_wrap(const SecurityPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.textContaining('shell.exec'), findsOneWidget);
    expect(find.textContaining('risk high'), findsOneWidget);
    expect(find.textContaining('s-1'), findsOneWidget);
  });

  testWidgets('snapshot null menampilkan pesan dan tombol refresh hadir',
      (tester) async {
    var refresh = 0;
    await tester.pumpWidget(_wrap(SecurityPage(
      snapshot: null,
      online: true,
      loading: false,
      onRefresh: () async {
        refresh += 1;
      },
    )));
    await tester.pump();

    expect(find.text('Belum ada data keamanan.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    expect(refresh, 1);
  });
}
