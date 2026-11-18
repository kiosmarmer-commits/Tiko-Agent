import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/runs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run-inspector (GUI-P2-04) view: daftar aktif/riwayat + expansion langkah.
void main() {
  RunEntry activeRun() => RunEntry.fromMap({
        'id': 'run-1',
        'session': 'web:1',
        'channel': 'web',
        'subagent': false,
        'parent': null,
        'input': 'buat laporan mingguan',
        'state': 'running',
        'started_at': '2026-11-18T13:00:00.000Z',
        'steps': [
          {
            'tool': 'datetime',
            'verdict': 'allowed',
            'is_error': false,
            'duration_ms': 12,
            'at': '2026-11-18T13:00:01.000Z',
          },
          {
            'tool': 'write_file',
            'verdict': 'allowed',
            'is_error': true,
            'duration_ms': 90,
            'at': '2026-11-18T13:00:02.000Z',
          },
        ],
      });

  RunEntry doneRun() => RunEntry.fromMap({
        'id': 'run-2',
        'session': 'web:1/sub/1/1',
        'channel': 'web',
        'subagent': true,
        'parent': 'web:1',
        'input': 'sub tugas',
        'state': 'done',
        'started_at': '2026-11-18T12:00:00.000Z',
        'ended_at': '2026-11-18T12:00:02.000Z',
        'duration_ms': 2000,
        'success': true,
        'tokens_used': 80,
        'tool_calls': 1,
        'answer': 'selesai',
        'steps': [
          {
            'tool': 'datetime',
            'verdict': 'allowed',
            'is_error': false,
            'duration_ms': 5,
            'at': '2026-11-18T12:00:01.000Z',
          },
        ],
      });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('menampilkan badge RUNNING + riwayat SELESAI dan subagent',
      (tester) async {
    await tester.pumpWidget(wrap(RunsPage(
      snapshot: RunsSnapshot(
          active: [activeRun()], recent: [doneRun()], truncated: false),
      online: true,
      loading: false,
      onRefresh: () async {},
    )));
    await tester.pump();

    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('SELESAI'), findsOneWidget);
    expect(find.text('buat laporan mingguan'), findsOneWidget);
    expect(find.text('sub tugas'), findsOneWidget);
    expect(find.textContaining('subagent dari web:1'), findsOneWidget);
    expect(find.text('RIWAYAT'), findsOneWidget);
    expect(find.text('AKTIF'), findsOneWidget);
  });

  testWidgets('expansion menampilkan langkah tool dengan status error',
      (tester) async {
    await tester.pumpWidget(wrap(RunsPage(
      snapshot: RunsSnapshot(
          active: [activeRun()], recent: const [], truncated: false),
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.textContaining('datetime'), findsNothing);
    await tester.tap(find.text('buat laporan mingguan'));
    await tester.pumpAndSettle();

    expect(find.textContaining('datetime'), findsOneWidget);
    expect(find.textContaining('write_file'), findsOneWidget);
    expect(find.textContaining('GAGAL'), findsNothing);
  });

  testWidgets('flag error pada run riwayat ditampilkan', (tester) async {
    await tester.pumpWidget(wrap(RunsPage(
      snapshot: RunsSnapshot(
          active: const [],
          recent: [
            RunEntry.fromMap({
              'id': 'run-3',
              'session': 'cli:default',
              'channel': 'cli',
              'state': 'error',
              'error': 'provider down',
              'success': false,
              'steps': [],
            }),
          ],
          truncated: false),
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('ERROR'), findsOneWidget);
    expect(find.text('Tidak ada panggilan tool dalam run ini.'), findsNothing);
  });

  testWidgets('snapshot kosong menampilkan placeholder', (tester) async {
    await tester.pumpWidget(wrap(RunsPage(
      snapshot: RunsSnapshot(active: const [], recent: const [], truncated: false),
      online: true,
      loading: false,
      onRefresh: () async {},
    )));
    await tester.pump();
    expect(find.text('Belum ada run terekam.'), findsOneWidget);
  });

  testWidgets('null snapshot menampilkan instruksi refresh', (tester) async {
    await tester.pumpWidget(wrap(RunsPage(
      snapshot: null,
      online: false,
      loading: false,
      error: 'koneksi gagal',
      onRefresh: () async {},
    )));
    await tester.pump();
    expect(find.text('koneksi gagal'), findsOneWidget);
    expect(find.text('Belum ada snapshot \u2014 tekan refresh.'), findsOneWidget);
  });
}
