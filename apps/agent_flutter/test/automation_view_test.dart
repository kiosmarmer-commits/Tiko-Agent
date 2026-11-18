import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/automation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(AutomationPage page) => MaterialApp(home: Scaffold(body: page));

const _snapshot = JobsSnapshot(
  jobs: [
    JobInfo(
      id: 'job-1',
      cron: '*/5 * * * *',
      prompt: 'ringkas berita',
      channel: 'http',
      userKey: 'admin',
      nextRun: '2026-11-18T13:00:00.000Z',
    ),
    JobInfo(
      id: 'job-2',
      cron: '0 9 * * *',
      prompt: 'backup harian telegram',
      channel: 'telegram',
      userKey: 'scheduler',
      nextRun: '2026-11-19T02:00:00.000Z',
      lastRun: '2026-11-18T02:00:00.000Z',
      enabled: false,
      missedPolicy: 'skip',
      timezone: 'Asia/Jakarta',
      deliveryState: 'delivered',
    ),
  ],
);

void main() {
  testWidgets('menampilkan job: prompt, cron, timezone, badge ON/OFF',
      (tester) async {
    await tester.pumpWidget(_wrap(const AutomationPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('ringkas berita'), findsOneWidget);
    expect(find.text('backup harian telegram'), findsOneWidget);
    expect(find.textContaining('*/5 * * * *'), findsOneWidget);
    expect(find.text('ON'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('delivery delivered'), findsOneWidget);
    expect(find.textContaining('missed skip'), findsOneWidget);
    expect(find.textContaining('Asia/Jakarta'), findsOneWidget);
  });

  testWidgets('kondisi kosong: snapshot null menampilkan pesan',
      (tester) async {
    await tester.pumpWidget(_wrap(const AutomationPage(
      snapshot: null,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Belum ada data job.'), findsOneWidget);
  });

  testWidgets('tombol Run now memanggil onRunNow dan refresh',
      (tester) async {
    var run = 0;
    await tester.pumpWidget(_wrap(AutomationPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onRunNow: (id) async {
        run++;
        return id == 'job-2' ? null : _snapshot.jobs.first;
      },
    )));
    await tester.pump();

    final runs = find.text('Run now');
    expect(runs, findsNWidgets(2));
    await tester.tap(runs.first);
    await tester.pump();
    expect(run, 1);
  });

  testWidgets('Run now gagal (null untuk job busy) menampilkan snackbar',
      (tester) async {
    await tester.pumpWidget(_wrap(AutomationPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onRunNow: (id) async => null,
    )));
    await tester.pump();

    final runs = find.text('Run now');
    expect(runs, findsNWidgets(2));
    await tester.tap(runs.first);
    await tester.pump();
    expect(find.textContaining('Gagal memicu job'), findsOneWidget);
  });

  testWidgets('Switch toggle memanggil onUpdate dengan enabled baru',
      (tester) async {
    final updates = <Map<String, dynamic>>[];
    await tester.pumpWidget(_wrap(AutomationPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onUpdate: (id, body) async => updates.add(body),
    )));
    await tester.pump();

    final switchKey = find.byType(Switch).first;
    await tester.tap(switchKey);
    await tester.pump();

    expect(updates, [{'enabled': false}]);
  });

  testWidgets('tombol + (online) membuka dialog create dan mengirim body',
      (tester) async {
    final created = <String>[];
    await tester.pumpWidget(_wrap(AutomationPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onCreate: (body) async => created.add('${body['cron']}'),
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Cron (5 field)').first,
        '*/10 * * * *');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prompt'), 'tes cron dari GUI');

    await tester.tap(find.widgetWithText(FilledButton, 'Buat'));
    await tester.pumpAndSettle();

    expect(created, ['*/10 * * * *']);
  });
}
