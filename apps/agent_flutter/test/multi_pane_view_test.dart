import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/multi_pane_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SessionsPane merender sesi, menandai sesi aktif, onSelect', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsPane(
            sessions: const [
              SessionSummary(id: 'web:default', title: 'Sesi Web', turns: 4),
              SessionSummary(
                id: 'flutter:default',
                title: 'Sesi Flutter',
                turns: 2,
              ),
            ],
            current: 'flutter:default',
            online: true,
            loading: false,
            onSelect: (id) => selected = id,
          ),
        ),
      ),
    );

    expect(find.text('Sesi Web'), findsOneWidget);
    expect(find.text('Sesi Flutter'), findsOneWidget);

    await tester.tap(find.text('Sesi Web'));
    expect(selected, 'web:default');
  });

  testWidgets('InspectorPane tab Runs memuat run dan refresh', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InspectorPane(
            runsSnapshot: RunsSnapshot(
              active: [
                RunEntry(
                  id: 'r1',
                  session: 'flutter:default',
                  channel: 'ws',
                  subagent: false,
                  parent: null,
                  input: 'rencanakan deployment',
                  state: 'running',
                  startedAt: '2026-11-18',
                  endedAt: null,
                  durationMs: null,
                  success: null,
                  tokensUsed: 12,
                  toolCalls: 1,
                  answer: null,
                  error: null,
                  steps: const [],
                ),
              ],
              recent: const [],
              truncated: false,
            ),
            runsLoading: false,
            runsError: null,
            artifactsListing: null,
            artifactsError: null,
            online: true,
            onLoadRuns: () => refreshed++,
          ),
        ),
      ),
    );

    expect(find.text('RUNNING'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    expect(refreshed, 1);
  });

  testWidgets('InspectorPane tab Files membuka artifact terpilih', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InspectorPane(
            runsSnapshot: null,
            runsLoading: false,
            runsError: null,
            artifactsListing: ArtifactsListing(
              files: [const ArtifactFileInfo(path: 'runs/out.md', bytes: 99)],
            ),
            artifactsError: null,
            online: true,
            onLoadRuns: () {},
            onLoadArtifacts: () {},
            onOpenArtifactFile: opened.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('runs/out.md'), findsOneWidget);

    await tester.tap(find.text('runs/out.md'));
    expect(opened, ['runs/out.md']);
  });

  testWidgets('InspectorPane tombol tutup memanggil onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InspectorPane(
            runsSnapshot: null,
            runsLoading: false,
            runsError: null,
            artifactsListing: null,
            artifactsError: null,
            online: true,
            onClose: () => closed = true,
          ),
        ),
      ),
    );

    expect(find.text('Belum ada snapshot — tekan muat ulang.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, isTrue);
  });
}
