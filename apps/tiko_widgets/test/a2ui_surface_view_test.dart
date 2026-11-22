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

  testWidgets('TikoSurfaceOrMessageView mencampur markdown + genui + a2ui',
      (tester) async {
    final text = 'Ringkasan:\n'
        '```genui\n'
        '{"type":"text","text":"halo genui"}\n'
        '```\n'
        '```a2ui\n'
        '${jsonLine}\n'
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
}

final jsonLine =
    '{"version":"1.0","createSurface":{"surfaceId":"s-inline","components":'
    '[{"id":"root","component":"Divider"}]}}';
