import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/a2ui_page_surface_section.dart';
import 'package:agent_flutter/ui/tasks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> entry(String surfaceId) => {
        'surfaceId': surfaceId,
        'sessionKey': 'flutter:default',
        'updatedAt': '2026-11-20T00:00:00.000Z',
      };

  Map<String, dynamic> detail(String surfaceId) => {
        'surfaceId': surfaceId,
        'catalogId': 'tiko.basic.v1',
        'components': [
          {'id': 'root', 'component': 'Column', 'children': ['t1', 'b1']},
          {
            'id': 't1',
            'component': 'Text',
            'text': 'Halo dari agent',
          },
          {
            'id': 'b1',
            'component': 'Button',
            'label': 'Segarkan papan',
            'action': {'name': 'refresh_board', 'payload': {}},
          },
        ],
        'dataModel': {},
      };

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  test('surfaceTargetsPage: prefix page.<target> dan case-insensitive', () {
    expect(A2uiPageSurfaceSection.surfaceTargetsPage('page.tasks.sa', 'tasks'),
        isTrue);
    expect(
        A2uiPageSurfaceSection.surfaceTargetsPage('Page.Tasks.SA', 'Tasks'),
        isTrue);
    expect(
        A2uiPageSurfaceSection.surfaceTargetsPage('page.tasks', 'tasks'),
        isTrue);
    expect(
        A2uiPageSurfaceSection.surfaceTargetsPage(
            'page.tasksboard.sa', 'tasks'),
        isFalse);
    expect(
        A2uiPageSurfaceSection.surfaceTargetsPage('chat.preview', 'tasks'),
        isFalse);
    expect(A2uiPageSurfaceSection.surfaceTargetsPage('', 'tasks'), isFalse);
  });

  testWidgets('section tersembunyi bila snapshot null atau tak ada match',
      (tester) async {
    await tester.pumpWidget(wrap(A2uiPageSurfaceSection(
      target: 'tasks',
      surfaces: null,
    )));
    expect(find.text('UI dinamis agent (A2UI)'), findsNothing);

    await tester.pumpWidget(wrap(A2uiPageSurfaceSection(
      target: 'tasks',
      surfaces: [entry('chat.preview')],
    )));
    expect(find.text('UI dinamis agent (A2UI)'), findsNothing);
  });

  testWidgets('section merender surface milik halaman dan mengabaikan lainnya',
      (tester) async {
    await tester.pumpWidget(wrap(A2uiPageSurfaceSection(
      target: 'tasks',
      surfaces: [entry('page.tasks.panel'), entry('chat.preview')],
      onLoadSurface: (surfaceId) async => detail(surfaceId),
    )));

    expect(
        find.textContaining('UI dinamis agent (A2UI)'), findsOneWidget);
    expect(find.text('page.tasks.panel'), findsOneWidget);
    expect(find.text('chat.preview'), findsNothing);
  });

  testWidgets('expand memuat detail dan merender komponen + aksi tombol '
      '(Hermes S8)', (tester) async {
    final loaded = <String>[];
    final actions = <List<Object>>[];

    await tester.pumpWidget(wrap(A2uiPageSurfaceSection(
      target: 'tasks',
      surfaces: [entry('page.tasks.panel')],
      onLoadSurface: (surfaceId) async {
        loaded.add(surfaceId);
        return detail(surfaceId);
      },
      onAction: (surfaceId, actionName, payload, sessionKey) =>
          actions.add([surfaceId, actionName, payload, sessionKey]),
    )));
    await tester.tap(find.text('page.tasks.panel'));
    await tester.pumpAndSettle();

    expect(loaded, ['page.tasks.panel']);
    expect(find.text('Halo dari agent'), findsOneWidget);
    expect(find.text('Segarkan papan'), findsOneWidget);

    await tester.tap(find.text('Segarkan papan'));
    expect(actions, hasLength(1));
    expect(actions.first[0], 'page.tasks.panel');
    expect(actions.first[1], 'refresh_board');
    expect(actions.first[3], 'flutter:default');
  });

  testWidgets('tombol Kelola dan Hapus memanggil callback', (tester) async {
    final deleted = <String>[];
    var managed = 0;

    await tester.pumpWidget(wrap(A2uiPageSurfaceSection(
      target: 'tasks',
      surfaces: [entry('page.tasks.panel')],
      onOpenManager: () => managed++,
      onDelete: (surfaceId) async {
        deleted.add(surfaceId);
        return true;
      },
      onLoadSurface: (surfaceId) async => detail(surfaceId),
    )));

    await tester.tap(find.byKey(const Key('btn-page-surface-manager')));
    expect(managed, 1);

    await tester.tap(find.byKey(const Key('btn-page-surface-delete-page.tasks.panel')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Hapus'));
    await tester.pumpAndSettle();
    expect(deleted, ['page.tasks.panel']);
  });

  testWidgets('TaskBoardPage menerima surfaceSection dinamis (Hermes S8)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskBoardPage(
          tasks: const [
            TaskItem(id: 't1', title: 'rapikan README', state: 'done'),
          ],
          online: true,
          loading: false,
          surfaceSection: A2uiPageSurfaceSection(
            target: 'tasks',
            surfaces: [entry('page.tasks.panel')],
            onLoadSurface: (surfaceId) async => detail(surfaceId),
          ),
        ),
      ),
    ));

    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('page.tasks.panel'), findsOneWidget);
    expect(find.text('ranikan README'.replaceFirst('ranikan', 'rapikan')),
        findsOneWidget);
  });
}
