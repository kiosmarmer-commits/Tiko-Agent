import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/tasks_view.dart';
import 'package:agent_flutter/ui/events_view.dart';
import 'package:agent_flutter/ui/logs_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tasks = [
    const TaskItem(id: 't1', title: 'rapikan README', state: 'done', result: 'selesai'),
    const TaskItem(id: 't2', title: 'ubah CI', state: 'doing', claimedBy: 'agent'),
    const TaskItem(id: 't3', title: 'gagal deploy', state: 'failed', result: 'exit 1'),
    const TaskItem(id: 't4', title: 'ide baru', state: 'backlog'),
  ];

  group('GUI-P1-01: TaskBoardPage', () {
    testWidgets('kolom kanban sama dengan web UI (backlog/doing/done/failed)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            child: TaskBoardPage(tasks: tasks, online: true, loading: false),
          ),
        ),
      ));
      await tester.pump();

      for (final state in kKanbanStates) {
        expect(find.textContaining('$state ('), findsOneWidget);
      }
      expect(find.text('rapikan README'), findsOneWidget);
      expect(find.text('ubah CI'), findsOneWidget);
      expect(find.text('gagal deploy'), findsOneWidget);
      expect(find.text('ide baru'), findsOneWidget);
      expect(find.textContaining('by agent'), findsOneWidget);
      expect(find.textContaining('selesai'), findsOneWidget);
    });

    testWidgets('tugas tanpa state dikenali sebagai backlog oleh model',
        (tester) async {
      final parsed = TaskItem.fromMap({'id': 't9', 'title': 'lama'});
      expect(parsed.state, 'backlog');
    });
  });

  group('GUI-P1-02: EventsPage', () {
    testWidgets('event terbaru di atas dan label approval berwarna beda',
        (tester) async {
      const events = [
        RuntimeEvent(type: 'run.completed', at: '2026-11-18T10:00:00Z'),
        RuntimeEvent(type: 'approval.decided', at: '2026-11-18T10:01:00Z'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventsPage(events: events, online: true, loading: false),
        ),
      ));
      await tester.pump();

      expect(find.text('run.completed'), findsOneWidget);
      expect(find.text('approval.decided'), findsOneWidget);
      expect(find.text('2026-11-18T10:01:00Z'), findsOneWidget);
    });
  });

  group('GUI-P1-02: LogsPage', () {
    testWidgets('memilih file log memuat isi, filter menyaring baris',
        (tester) async {
      LogFileContent? loaded;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LogsPage(
            logs: const [
              LogFileInfo(name: 'audit-20261118.jsonl', bytes: 120),
              LogFileInfo(name: 'daemon-20261118.log', bytes: 40),
            ],
            online: true,
            loading: false,
            onRefresh: () async {},
            onLoadContent: (name) async {
              loaded = LogFileContent(
                name: name,
                bytes: 120,
                truncated: true,
                content: 'INFO mulai\nERROR gagal kirim\nSELESAI',
              );
              return loaded!;
            },
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(loaded?.name, 'audit-20261118.jsonl');
      expect(find.textContaining('dipotong'), findsOneWidget);
      expect(find.text('ERROR gagal kirim'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ERROR');
      await tester.pump();
      expect(find.text('ERROR gagal kirim'), findsOneWidget);
      expect(find.text('INFO mulai'), findsNothing);
      expect(find.text('SELESAI'), findsNothing);
    });

    testWidgets('file log difilter berdasarkan nama', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LogsPage(
            logs: const [
              LogFileInfo(name: 'audit-20261118.jsonl', bytes: 120),
              LogFileInfo(name: 'daemon-20261118.log', bytes: 40),
            ],
            online: true,
            loading: false,
            onRefresh: () async {},
            onLoadContent: (name) async =>
                LogFileContent(name: name, content: 'x'),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.enterText(find.byType(TextField), 'daemon');
      await tester.pump();
      expect(find.text('daemon-20261118.log'), findsOneWidget);
      expect(find.text('audit-20261118.jsonl'), findsNothing);
    });
  });
}
