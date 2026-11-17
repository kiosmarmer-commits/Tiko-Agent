import 'package:agent_flutter/ui/gen_ui_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? lastAction;
  Map<String, dynamic>? lastValues;

  Widget host(String text) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GenUiMessageView(
              text: text,
              onAction: (id, values) {
                lastAction = id;
                lastValues = values;
              },
            ),
          ),
        ),
      );

  setUp(() {
    lastAction = null;
    lastValues = null;
  });

  testWidgets('teks biasa tanpa blok genui dirender sebagai teks',
      (tester) async {
    await tester.pumpWidget(host('Halo dunia'));
    expect(find.text('Halo dunia'), findsOneWidget);
    expect(find.byType(GenUiView), findsNothing);
  });

  testWidgets('blok genui teks + heading dirender sebagai widget',
      (tester) async {
    await tester.pumpWidget(host(
      'Berikut ringkasannya:\n\n```genui\n'
      '{"type":"section","title":"Laporan","children":['
      '{"type":"text","text":"Pendapatan naik","style":"heading"},'
      '{"type":"metric","label":"Total","value":1200,"delta":-2.5}'
      ']}\n```\n\nSelesai.',
    ));
    expect(find.text('Laporan'), findsOneWidget);
    expect(find.text('Pendapatan naik'), findsOneWidget);
    expect(find.text('1200'), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsOneWidget);
    expect(find.textContaining('Selesai.'), findsOneWidget);
    // Blok mentah tidak ditampilkan sebagai teks.
    expect(find.textContaining('```genui'), findsNothing);
  });

  testWidgets('chart bar dirender dengan label dan nilai', (tester) async {
    await tester.pumpWidget(host(
      '```genui\n'
      '{"type":"chart","chart":"bar","points":['
      '{"label":"Sen","value":3},{"label":"Sel","value":7}]}\n'
      '```',
    ));
    expect(find.text('Sen'), findsOneWidget);
    expect(find.text('Sel'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
  });

  testWidgets('chart line dirender via CustomPaint', (tester) async {
    await tester.pumpWidget(host(
      '```genui\n'
      '{"type":"chart","chart":"line","points":['
      '{"label":"a","value":1},{"label":"b","value":5},'
      '{"label":"c","value":3}]}\n'
      '```',
    ));
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('divider dan actions dirender; tombol memicu onAction',
      (tester) async {
    await tester.pumpWidget(host(
      '```genui\n'
      '{"type":"section","title":"Konfirmasi","children":['
      '{"type":"divider"},'
      '{"type":"actions","buttons":['
      '{"id":"approve","label":"Setuju"},'
      '{"id":"delete","label":"Hapus","style":"danger"}]}]}\n'
      '```',
    ));
    expect(find.byType(Divider), findsOneWidget);
    await tester.tap(find.text('Setuju'));
    expect(lastAction, 'approve');
    expect(lastValues, isEmpty);
    await tester.tap(find.text('Hapus'));
    expect(lastAction, 'delete');
  });

  testWidgets('form: isi field, validasi, submit mengirim nilai',
      (tester) async {
    await tester.pumpWidget(host(
      '```genui\n'
      '{"type":"form","id":"f1","title":"Data diri","fields":['
      '{"name":"nama","label":"Nama"},'
      '{"name":"usia","label":"Usia","kind":"number"},'
      '{"name":"paket","label":"Paket","kind":"select",'
      '"options":["A","B"]}]}\n'
      '```',
    ));
    expect(find.text('Data diri'), findsOneWidget);

    // Submit tanpa isi -> validasi menolak (tidak ada onAction).
    await tester.tap(find.text('Kirim'));
    await tester.pump();
    expect(lastAction, isNull);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Nama').first, 'Budi');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Usia').first, '30');
    await tester.tap(find.text('Paket'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kirim'));
    await tester.pump();
    expect(lastAction, 'f1');
    expect(lastValues, {'nama': 'Budi', 'usia': '30', 'paket': 'A'});
  });

  testWidgets('blok genui tidak valid tetap tampil sebagai teks (fail-closed)',
      (tester) async {
    final text = '```genui\n{"type":"webview","src":"http://evil"}\n```';
    await tester.pumpWidget(host(text));
    expect(find.byType(GenUiView), findsNothing);
    expect(find.textContaining('webview'), findsOneWidget);
  });

  testWidgets('pesan campuran: teks, dua blok UI, teks', (tester) async {
    await tester.pumpWidget(host(
      'Intro\n```genui\n{"type":"divider"}\n```\nTengah\n'
      '```genui\n{"type":"text","text":"Nilai"}\n```\nOutro',
    ));
    expect(find.textContaining('Intro'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('Nilai'), findsOneWidget);
    expect(find.textContaining('Outro'), findsOneWidget);
  });
}
