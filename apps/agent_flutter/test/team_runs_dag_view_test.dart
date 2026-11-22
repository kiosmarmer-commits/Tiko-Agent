import 'package:agent_flutter/ui/runs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// DAG view run team (Fase E5): bagian laporan run tim di halaman Runs,
/// level DAG, dan detail sheet per task.
Map<String, dynamic> report() => {
      'run_id': 'r-team-9',
      'goal': 'Perbaiki linter',
      'success': true,
      'plan_source': 'planner',
      'plan': [
        {'id': 't1', 'prompt': 'scan dulu', 'agent_id': 'planner-1'},
        {
          'id': 't2',
          'prompt': 'perbaiki file',
          'agent_id': 'coder-1',
          'depends_on': ['t1'],
        },
        {
          'id': 't3',
          'prompt': 'verifikasi',
          'agent_id': 'reviewer-1',
          'depends_on': ['t1', 't2'],
        },
      ],
      'nodes': [
        {'node_id': 't1', 'ok': true},
        {'node_id': 't2', 'ok': true},
        {'node_id': 't3', 'ok': false, 'error': 'wat'},
      ],
      'synthesis': 'dua dari tiga tugas sukses',
      'tokens_used': 4321,
    };

void main() {
  test('teamRunPlanTasks: level DAG terhitung + urut level lalu rencana', () {
    final tasks = teamRunPlanTasks(report());
    expect(tasks.map((t) => t.id).toList(), containsAllInOrder(['t1', 't2']));
    final levels = {for (final t in tasks) t.id: t.level};
    expect(levels, {'t1': 0, 't2': 1, 't3': 2});
    expect(tasks.firstWhere((t) => t.id == 't3').ok, isFalse);
    expect(tasks.firstWhere((t) => t.id == 't1').agentId, 'planner-1');
  });

  test('teamRunPlanTasks fail-closed: plan kosong/korup -> list kosong', () {
    expect(teamRunPlanTasks(<String, dynamic>{}), isEmpty);
    expect(
      teamRunPlanTasks({
        'plan': [
          {'id': ''},
          'rusak',
          {'id': 'a', 'depends_on': []},
        ],
      }).map((t) => t.id),
      ['a'],
    );
  });

  testWidgets('halaman Runs menampilkan bagian run tim dan DAG sheet',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RunsPage(
          snapshot: null,
          online: true,
          loading: false,
          teamRuns: [report()],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('RUN TEAM (Fase C)'), findsOneWidget);
    expect(find.text('Perbaiki linter'), findsOneWidget);
    expect(find.text('SUKSES'), findsOneWidget);

    await tester.tap(find.text('Perbaiki linter'));
    await tester.pumpAndSettle();

    expect(find.textContaining('DAG run r-team-9'), findsOneWidget);
    expect(find.text('scan dulu'), findsOneWidget);
    expect(find.text('depends: t1, t2'), findsOneWidget);
    expect(find.text('gagal'), findsOneWidget);
    expect(find.text('dua dari tiga tugas sukses'), findsOneWidget);
  });

  testWidgets('run team tanpa rencana menampilkan pesan fail-closed',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RunsPage(
          snapshot: null,
          online: true,
          loading: false,
          teamRuns: [
            {
              'run_id': 'r-team-x',
              'goal': 'tanpa plan',
              'success': false,
            },
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tanpa plan'));
    await tester.pumpAndSettle();
    expect(find.text('Rencana DAG tidak tersedia pada laporan ini.'),
        findsOneWidget);
  });
}
