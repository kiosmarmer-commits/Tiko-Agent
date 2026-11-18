import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/audit_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(AuditPage page) => MaterialApp(home: Scaffold(body: page));

const _result = AuditQueryResult(
  total: 3,
  entries: [
    AuditEntry(
      ts: '2026-11-18T13:00:00.000Z',
      session: 'web:default',
      tool: 'shell.exec',
      args: {'cmd': 'ls'},
      risk: 'high',
      verdict: 'approve',
      result: 'ok',
      durationMs: 42,
    ),
    AuditEntry(
      ts: '2026-11-18T12:59:00.000Z',
      session: 's-2',
      tool: 'file.write',
      risk: 'high',
      verdict: 'deny',
      error: 'ditolak guard',
      taint: true,
    ),
  ],
);

void main() {
  testWidgets('menampilkan header total + entri dengan tool/risk/verdict',
      (tester) async {
    await tester.pumpWidget(_wrap(const AuditPage(
      result: _result,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('3 entri cocok · menampilkan 2'), findsOneWidget);
    expect(find.text('shell.exec'), findsOneWidget);
    expect(find.text('file.write'), findsOneWidget);
    expect(find.textContaining('42ms'), findsOneWidget);
    expect(find.textContaining('TAINT'), findsOneWidget);
    expect(find.textContaining('ditolak guard'), findsOneWidget);
    expect(find.textContaining('cmd: ls'), findsOneWidget);
  });

  testWidgets('tombol cari mengirim filter ke onQuery', (tester) async {
    Map<String, String>? sent;
    await tester.pumpWidget(_wrap(AuditPage(
      result: null,
      online: true,
      loading: false,
      onQuery: (filters) async {
        sent = filters;
      },
    )));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, '').first, 'shell');
    await tester.tap(find.widgetWithText(FilledButton, 'Cari'));
    await tester.pump();

    expect(sent, isNotNull);
    expect(sent!['tool'], 'shell');
  });

  testWidgets('kondisi kosong: result null dan entries kosong', (tester) async {
    await tester.pumpWidget(_wrap(const AuditPage(
      result: null,
      online: true,
      loading: false,
    )));
    await tester.pump();
    expect(find.textContaining('Belum ada query audit'), findsOneWidget);

    await tester.pumpWidget(_wrap(const AuditPage(
      result: AuditQueryResult(total: 0),
      online: true,
      loading: false,
    )));
    await tester.pump();
    expect(find.text('Tidak ada entri yang cocok.'), findsOneWidget);
  });

  testWidgets('error menampilkan pesan; tombol refresh memanggil onRefresh',
      (tester) async {
    var refresh = 0;
    await tester.pumpWidget(_wrap(AuditPage(
      result: null,
      online: true,
      loading: false,
      error: '501 not_implemented',
      onQuery: (_) async {},
      onRefresh: () async {
        refresh += 1;
      },
    )));
    await tester.pump();

    expect(find.text('501 not_implemented'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    expect(refresh, 1);
  });
}
