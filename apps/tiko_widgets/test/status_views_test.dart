import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

void main() {
  testWidgets('errorBanner menampilkan pesan dan tombol retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: StatusViews.errorBanner(
              context,
              'Gagal memuat data',
              onRetry: () => retried++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Gagal memuat data'), findsOneWidget);
    expect(find.text('Coba lagi'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('status_views_retry')));
    expect(retried, 1);
  });

  testWidgets('errorBanner tanpa retry hanya menampilkan pesan', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) =>
              Scaffold(body: StatusViews.errorBanner(context, 'Koneksi gagal')),
        ),
      ),
    );

    expect(find.text('Koneksi gagal'), findsOneWidget);
    expect(find.text('Coba lagi'), findsNothing);
  });

  testWidgets('empty menampilkan ikon dan pesan kosong', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: StatusViews.empty(
              context,
              message: 'Belum ada artifact',
              action: TextButton(onPressed: () {}, child: const Text('Unggah')),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.text('Belum ada artifact'), findsOneWidget);
    expect(find.text('Unggah'), findsOneWidget);
  });

  testWidgets('empty dengan detail menampilkan subteks', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: StatusViews.empty(
              context,
              message: 'Tidak ditemukan',
              detail: 'Coba kata kunci lain.',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Tidak ditemukan'), findsOneWidget);
    expect(find.text('Coba kata kunci lain.'), findsOneWidget);
  });

  testWidgets('loadingBanner menampilkan label memuat dengan Semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: StatusViews.loadingBanner(
              context,
              label: 'Menyinkronkan\u2026',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Menyinkronkan\u2026'), findsOneWidget);
    expect(find.byType(Semantics), findsWidgets);
  });
}
