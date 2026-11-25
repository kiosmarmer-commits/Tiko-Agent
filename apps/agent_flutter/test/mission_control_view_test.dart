import 'package:agent_flutter/ui/mission_control_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mission Control (Hermes S16): halaman dashboard live run orkestra tim —
/// polling onRefresh, chip status per run/nodes, progress node, tombol Stop,
/// empty state, dan error banner.

Map<String, dynamic> _node(
  String id, {
  String agent = 'coder',
  String status = 'ok',
  String? output,
  String? error,
  String? started,
  String? finished,
}) =>
    {
      'id': id,
      'agent': agent,
      'status': status,
      if (output != null) 'output_tail': output,
      if (error != null) 'error': error,
      if (started != null) 'started_at': started,
      if (finished != null) 'finished_at': finished,
    };

Map<String, dynamic> _run(
  String runId, {
  String status = 'running',
  List<Map<String, dynamic>>? nodes,
  String goal = 'Perbaiki bug compiler',
  String teamId = 'paket-ui',
}) =>
    {
      'run_id': runId,
      'team_id': teamId,
      'goal': goal,
      'status': status,
      'nodes': nodes ?? const [],
    };

Widget host(MissionControlView view) =>
    MaterialApp(home: Scaffold(body: view));

void main() {
  testWidgets('halaman kosong (belum dimuat) menampilkan empty state',
      (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: null,
      onRefresh: null,
      autoRefresh: false,
    )));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Belum ada snapshot'), findsOneWidget);
  });

  testWidgets('kosong setelah dimuat: pesan beda tanpa spinner', (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: const [],
      loading: false,
      onRefresh: null,
      autoRefresh: false,
    )));
    expect(find.textContaining('Belum ada run tim aktif'), findsOneWidget);
  });

  testWidgets('render run aktif: chip status, progress, node, tombol Stop',
      (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [
        _run('r1', nodes: [
          _node('parse',
              status: 'ok', started: '2026-01-01T00:00:00Z',
              finished: '2026-01-01T00:00:02Z', output: '900ms rapi'),
          _node('build', status: 'running'),
          _node('verify', status: 'pending'),
        ]),
      ],
      autoRefresh: false,
    )));
    expect(find.text('Perbaiki bug compiler'), findsOneWidget);
    expect(find.text('run_id r1 · tim paket-ui'), findsOneWidget);
    expect(find.textContaining('Progress: 1/3 node selesai'), findsOneWidget);
    expect(find.text('BERJALAN'), findsOneWidget);
    expect(find.textContaining('parse \u00b7 coder'), findsOneWidget);
    expect(find.textContaining('2.0s'), findsOneWidget);
    expect(find.textContaining('build \u00b7 coder'), findsOneWidget);
    expect(find.text('ANTRI'), findsNothing);
    final stop = find.widgetWithText(OutlinedButton, 'Stop');
    expect(stop, findsOneWidget);
    expect(tester.widget<OutlinedButton>(stop).onPressed, isNotNull);
  });

  testWidgets('run selesai tidak menampilkan tombol Stop', (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [
        _run('r2', status: 'finished', nodes: [
          _node('main', status: 'ok'),
        ]),
        _run('r3', status: 'failed', nodes: [
          _node('main', status: 'failed', error: 'boom'),
        ]),
      ],
      autoRefresh: false,
    )));
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsNothing);
    expect(find.text('SELESAI'), findsOneWidget);
    expect(find.text('GAGAL'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    expect(find.textContaining('1/1 node selesai'), findsWidgets);
  });

  testWidgets('tekan Stop memanggil onCancelRun dan menampilkan snackbar',
      (tester) async {
    String? cancelled;
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [_run('r9')],
      onRefresh: () async {},
      onCancelRun: (runId) async {
        cancelled = runId;
        return true;
      },
      autoRefresh: false,
    )));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pump();
    expect(cancelled, 'r9');
    expect(find.textContaining('Sinyal stop dikirim'), findsOneWidget);
  });

  testWidgets('cancel gagal (run sudah selesai) menampilkan pesan lain',
      (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [_run('r1')],
      onRefresh: () async {},
      onCancelRun: (_) async => false,
      autoRefresh: false,
    )));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('tidak ditemukan atau sudah selesai'),
        findsOneWidget);
  });

  testWidgets('error tampil sebagai banner', (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: null,
      loading: false,
      error: 'koneksi gagal',
      onRefresh: null,
      autoRefresh: false,
    )));
    expect(find.text('koneksi gagal'), findsOneWidget);
  });

  testWidgets('run dengan status selesai tapi node masih running tetap aktif',
      (tester) async {
    // Race guard: node_started datang setelah runFinished tercatat —
    // kartu tetap terhitung aktif kalau ada node running/pending.
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [
        _run('r4', status: 'finished', nodes: [
          _node('main', status: 'running'),
        ]),
      ],
      autoRefresh: false,
    )));
    expect(find.text('1 run aktif'), findsOneWidget);
  });

  testWidgets('run cancelling: tombol Stop tampil nonaktif', (tester) async {
    await tester.pumpWidget(host(MissionControlView(
      online: true,
      runs: [_run('r5', status: 'cancelling')],
      autoRefresh: false,
    )));
    final stop = find.widgetWithText(OutlinedButton, 'Stop');
    expect(stop, findsOneWidget);
    expect(tester.widget<OutlinedButton>(stop).onPressed, isNull);
    expect(find.text('MEMBATALKAN'), findsOneWidget);
  });
}
