import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/session_history_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('history menampilkan judul manusiawi dan pencarian', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionHistoryView(
            sessions: const [
              SessionSummary(
                id: 'flutter:alpha',
                title: 'Riset produk',
                updatedAt: '2026-11-24T12:00:00Z',
                turns: 3,
              ),
              SessionSummary(
                id: 'flutter:untitled',
                updatedAt: '2026-11-24T11:00:00Z',
              ),
            ],
            current: 'flutter:alpha',
            online: true,
            loading: false,
            onRefresh: () async {},
            onSelect: (_) {},
            onRename: (_, __) async {},
            onDelete: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Riset produk'), findsOneWidget);
    expect(find.text('Percakapan tanpa judul'), findsOneWidget);
    expect(find.textContaining('3 turn'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'riset');
    await tester.pump();
    expect(find.text('Riset produk'), findsOneWidget);
    expect(find.text('Percakapan tanpa judul'), findsNothing);
  });
}
