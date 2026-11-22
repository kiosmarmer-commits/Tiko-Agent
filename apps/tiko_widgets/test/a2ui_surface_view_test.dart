import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

A2uiMessage createDashboard() =>
    parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-chip',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['t1', 'm1', 'ch1', 'b1'],
          },
          {
            'id': 't1',
            'component': 'Text',
            'text': 'Status sistem',
            'variant': 'heading',
          },
          {'id': 'm1', 'component': 'Metric', 'label': 'CPU', 'value': '87%'},
          {
            'id': 'ch1',
            'component': 'Chart',
            'kind': 'bar',
            'points': [
              {'label': '10:00', 'value': 64},
              {'label': '10:05', 'value': 87},
            ],
          },
          {
            'id': 'b1',
            'component': 'Button',
            'label': 'Jalankan pemeriksaan',
            'action': {'name': 'run_diag', 'payload': {'t': 'cpu'}},
          },
        ],
        'dataModel': {'cpu': 87},
      },
    }).first;

void main() {
  testWidgets('A2uiSurfaceStreamView merender Metric, Chart, dan tombol',
      (tester) async {
    var actionFired = false;
    String? firedName;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: A2uiSurfaceStreamView(
          messages: [createDashboard()],
          onAction: (surfaceId, actionName, payload) {
            actionFired = true;
            firedName = actionName;
          },
        ),
      ),
    ));

    expect(find.text('Status sistem'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('Jalankan pemeriksaan'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

    await tester.tap(find.byType(FilledButton).first);
    expect(actionFired, isTrue);
    expect(firedName, 'run_diag');
  });

  testWidgets('binding @path membaca data model', (tester) async {
    final parsed = parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-bind',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['t1'],
          },
          {'id': 't1', 'component': 'Text', 'text': {'@path': '/user/name'}},
        ],
        'dataModel': {
          'user': {'name': 'Andi'},
        },
      },
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: A2uiSurfaceStreamView(messages: parsed),
      ),
    ));
    expect(find.text('Andi'), findsOneWidget);
  });

  testWidgets('pesan tidak valid dirender kartu error, bukan crash',
      (tester) async {
    final parsed = parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-bad',
        'components': [
          {'id': 'root', 'component': 'Divider'},
        ],
      },
    }).toList();
    // Simulasikan tidak valid: buang root supaya fail-closed.
    final first = parsed.first as A2uiCreateSurface;
    final tampered = <A2uiMessage>[
      A2uiCreateSurface(
        surfaceId: first.surfaceId,
        components: first.components.skip(1).toList(),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: A2uiSurfaceStreamView(messages: tampered)),
    ));
    expect(find.textContaining('tidak dapat dirender'), findsOneWidget);
  });

  testWidgets('Chart kind donut dan area dirender tanpa exception',
      (tester) async {
    Widget chart(String kind) => A2uiSurfaceStreamView(messages: parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's-ch',
            'components': [
              {
                'id': 'root',
                'component': 'Chart',
                'kind': kind,
                'points': [
                  {'label': 'A', 'value': 10},
                  {'label': 'B', 'value': 24},
                  {'label': 'C', 'value': 6},
                ],
              },
            ],
          },
        }));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: chart('donut'))));
    await tester.pumpAndSettle();
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.textContaining('A · 10'), findsOneWidget);

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: chart('area'))));
    await tester.pumpAndSettle();
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('ApprovalSheet dirender: chip risiko, ringkasan, dan perintah',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: A2uiSurfaceStreamView(messages: parseA2uiMessages({
          'version': '1.0',
          'createSurface': {
            'surfaceId': 's-appr',
            'components': [
              {
                'id': 'root',
                'component': 'Column',
                'children': ['ap1', 'b1'],
              },
              {
                'id': 'ap1',
                'component': 'ApprovalSheet',
                'risk': 'high',
                'summary': 'Hapus 3 kontainer produksi',
                'commands': ['docker rm -f a', 'docker rm -f b'],
              },
              {
                'id': 'b1',
                'component': 'Button',
                'label': 'Setujui',
                'action': {'name': 'approve_delete'},
              },
            ],
          },
        })),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('persetujuan'), findsOneWidget);
    expect(find.textContaining('Hapus 3 kontainer'), findsOneWidget);
    expect(find.text('docker rm -f a'), findsOneWidget);
    expect(find.text('Setujui'), findsOneWidget);
  });

  testWidgets('fence a2ui yang belum tertutup menampilkan skeleton streaming',
      (tester) async {
    final text = 'Mulai:\n```a2ui\n'
        '{"version":"1.0","createSurface":{"surfaceId":"s-stream",'
        '"components":[{"id":"root","component":"Division"}]}}';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TikoSurfaceOrMessageView(text: text)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('sedang dibuat'), findsOneWidget);
    expect(find.byType(A2uiSurfaceStreamView), findsNothing);
  });

  testWidgets('A2uiSurfaceRecordView: record valid dirender, tampered gagal aman',
      (tester) async {
    final valid = {
      'surfaceId': 's-rec',
      'catalogId': 'tiko.basic.v1',
      'components': [
        {'id': 'root', 'component': 'Metric', 'label': 'CPU', 'value': '87%'},
      ],
      'dataModel': <String, dynamic>{},
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: A2uiSurfaceRecordView(record: valid)),
    ));
    expect(find.textContaining('CPU'), findsOneWidget);

    final tampered = {
      ...valid,
      'components': [
        {'id': 'not-root', 'component': 'Divider'},
      ],
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: A2uiSurfaceRecordView(record: tampered)),
    ));
    expect(find.textContaining('tidak dapat dirender'), findsOneWidget);
  });

  testWidgets('TikoSurfaceOrMessageView mencampur markdown + genui + a2ui',
      (tester) async {
    final text = 'Ringkasan:\n'
        '```genui\n'
        '{"type":"text","text":"halo genui"}\n'
        '```\n'
        '```a2ui\n'
        '$jsonLine\n'
        '```\n'
        'Selesai.';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TikoSurfaceOrMessageView(text: text)),
    ));
    expect(find.byType(GenUiView), findsOneWidget);
    expect(find.byType(A2uiSurfaceStreamView), findsOneWidget);
    expect(find.textContaining('Selesai'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('CheckBox input memicu onInput (Fase E6)', (tester) async {
    final messages = parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-chk',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['c1'],
          },
          {
            'id': 'c1',
            'component': 'CheckBox',
            'label': 'Setuju',
            'action': {'name': 'toggle_ok'},
          },
        ],
      },
    });
    String? firedComponent;
    String? firedAction;
    Object? firedValue;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: A2uiSurfaceStreamView(
          messages: messages,
          onInput: (surfaceId, componentId, actionName, value) {
            firedComponent = componentId;
            firedAction = actionName;
            firedValue = value;
          },
        ),
      ),
    ));

    await tester.tap(find.byType(Checkbox));
    expect(firedComponent, 'c1');
    expect(firedAction, 'toggle_ok');
    expect(firedValue, isTrue);
  });

  testWidgets('TextField tanpa onInput tetap editable lokal', (tester) async {
    final messages = parseA2uiMessages({
      'version': '1.0',
      'createSurface': {
        'surfaceId': 's-chk',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['f1'],
          },
          {'id': 'f1', 'component': 'TextField', 'label': 'Nama'},
        ],
      },
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: A2uiSurfaceStreamView(messages: messages),
      ),
    ));
      await tester.enterText(find.byType(TextField), 'Budi');
    expect(find.text('Budi'), findsOneWidget);
  });
}

final jsonLine =
    '{"version":"1.0","createSurface":{"surfaceId":"s-inline","components":'
    '[{"id":"root","component":"Divider"}]}}';
