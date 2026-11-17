import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

void main() {
  testWidgets('TikoChatInterface: pesan kosong menampilkan emptyMessage',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TikoChatInterface(messages: const [], onSend: (_) {}),
      ),
    ));
    expect(find.text('Mulai percakapan dengan agen.'), findsOneWidget);
  });

  testWidgets('TikoChatInterface: onSend terpanggil dengan teks ter-trim',
      (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TikoChatInterface(
          messages: const [],
          onSend: (t) => sent = t,
        ),
      ),
    ));
    await tester.enterText(find.byType(TextField), '  halo agen  ');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sent, 'halo agen');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('TikoChatInterface: busy menonaktifkan input', (tester) async {
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TikoChatInterface(
          messages: const [],
          busy: true,
          onSend: (_) => sent++,
        ),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'halo');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sent, 0, reason: 'input dinonaktifkan saat busy');
    expect(find.text('Memproses…'), findsOneWidget);
  });

  testWidgets('TikoChatInterface: bubble user vs assistant terpisah',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TikoChatInterface(
          messages: const [
            TikoChatMessage(role: 'user', text: 'pertanyaan'),
            TikoChatMessage(role: 'assistant', text: 'jawaban biasa'),
            TikoChatMessage(role: 'assistant', text: 'gagal', error: true),
          ],
          onSend: (_) {},
        ),
      ),
    ));
    expect(find.text('pertanyaan'), findsOneWidget);
    expect(find.text('jawaban biasa'), findsOneWidget);
    expect(find.text('gagal'), findsOneWidget);
  });

  test('TikoChatMessage default: error false', () {
    const m = TikoChatMessage(role: 'user', text: 'x');
    expect(m.error, isFalse);
  });
}
