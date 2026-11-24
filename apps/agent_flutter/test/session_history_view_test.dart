import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/session_history_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(
  String id, {
  String title = '',
  String channel = 'cli',
  String updatedAt = '2026-11-24T12:00:00Z',
  int turns = 0,
  String provider = '',
  String model = '',
  bool pinned = false,
  bool archived = false,
  bool lastFailed = false,
}) => SessionSummary(
      id: id,
      title: title,
      channel: channel,
      updatedAt: updatedAt,
      turns: turns,
      provider: provider,
      model: model,
      pinned: pinned,
      archived: archived,
      lastFailed: lastFailed,
    );

Future<void> _pump(WidgetTester tester, SessionHistoryView view) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: view)),
  );
  await tester.pump();
}

void main() {
  testWidgets('history menampilkan judul manusiawi dan pencarian', (
    tester,
  ) async {
    var newChatTapped = false;
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session('flutter:alpha', title: 'Riset produk', turns: 3),
          _session('flutter:untitled'),
        ],
        current: 'flutter:alpha',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onNewChat: () => newChatTapped = true,
      ),
    );

    expect(find.text('Riset produk'), findsOneWidget);
    expect(find.text('Percakapan tanpa judul'), findsOneWidget);
    expect(find.textContaining('3 turn'), findsOneWidget);
    expect(find.byKey(const Key('btn-history-new-chat')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-history-new-chat')));
    expect(newChatTapped, isTrue);

    await tester.enterText(find.byType(TextField), 'riset');
    await tester.pump();
    expect(find.text('Riset produk'), findsOneWidget);
    expect(find.text('Percakapan tanpa judul'), findsNothing);

    await tester.tap(find.byTooltip('Hapus pencarian'));
    await tester.pump();
    expect(find.text('Percakapan tanpa judul'), findsOneWidget);
  });

  testWidgets('menu opsi memanggil pin, arsip, dan duplikat', (tester) async {
    var pinned = false;
    var archived = false;
    String? duplicated;
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session(
            's1',
            title: 'Riset produk',
            provider: 'openai',
            model: 'gpt-x',
          ),
        ],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onTogglePin: (_, value) async => pinned = value,
        onToggleArchive: (_, value) async => archived = value,
        onDuplicate: (id) async => duplicated = id,
      ),
    );

    await tester.tap(find.byTooltip('Opsi percakapan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sematkan (pin)'));
    await tester.pumpAndSettle();
    expect(pinned, isTrue);

    await tester.tap(find.byTooltip('Opsi percakapan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arsipkan'));
    await tester.pumpAndSettle();
    expect(archived, isTrue);

    await tester.tap(find.byTooltip('Opsi percakapan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplikat fork'));
    await tester.pumpAndSettle();
    expect(duplicated, 's1');
  });

  testWidgets('menu ekspor mengirim format yang dipilih', (tester) async {
    final exported = <String>[];
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [_session('s1', title: 'Riset produk')],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onExport: (id, format) async => exported.add(format),
      ),
    );

    await tester.tap(find.byTooltip('Opsi percakapan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ekspor Markdown'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Opsi percakapan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ekspor JSON'));
    await tester.pumpAndSettle();

    expect(exported, ['md', 'json']);
  });

  testWidgets('chip filter memisahkan pinned dan arsip', (tester) async {
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session('s-pinned', title: 'Tersimpan', pinned: true),
          _session('s-archived', title: 'Tersimpan arsip', archived: true),
          _session('s-normal', title: 'Normal'),
        ],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onTogglePin: (_, __) async {},
        onToggleArchive: (_, __) async {},
      ),
    );

    expect(find.text('Tersimpan'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Tersimpan arsip'), findsNothing);

    await tester.tap(find.byKey(const Key('chip-history-view-archived')));
    await tester.pump();
    expect(find.text('Tersimpan arsip'), findsOneWidget);
    expect(find.text('Normal'), findsNothing);
    expect(find.text('Tersimpan'), findsNothing);

    await tester.tap(find.byKey(const Key('chip-history-view-pinned')));
    await tester.pump();
    expect(find.text('Tersimpan'), findsOneWidget);
    expect(find.text('Tersimpan arsip'), findsNothing);
  });

  testWidgets('dropdown filter channel dan provider/model', (tester) async {
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session('s-1', title: 'CLI old', provider: 'openai', model: 'gpt-x'),
          _session(
            's-2',
            title: 'Telegram',
            channel: 'telegram',
            provider: 'anthropic',
            model: 'sonnet',
          ),
        ],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onTogglePin: (_, __) async {},
        onToggleArchive: (_, __) async {},
      ),
    );

    expect(find.text('CLI old'), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-history-channel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('telegram').last);
    await tester.pump();
    expect(find.text('CLI old'), findsNothing);
    expect(find.text('Telegram'), findsOneWidget);
  });

  testWidgets('mode pilih lalu bulk delete memanggil callback', (tester) async {
    var deletedIds = <String>[];
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session('s-1', title: 'Satu'),
          _session('s-2', title: 'Dua'),
        ],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onBulkDelete: (ids) async => deletedIds = ids,
      ),
    );

    await tester.tap(find.byKey(const Key('btn-history-select')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('history-check-s-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('history-check-s-2')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('btn-history-bulk-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-history-bulk-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deletedIds, containsAll(['s-1', 's-2']));
    expect(find.text('0 dipilih'), findsNothing);
  });

  testWidgets('indikator gagal dan sematan tampil pada tile', (tester) async {
    await _pump(
      tester,
      SessionHistoryView(
        sessions: [
          _session('s-1', title: 'Gagal', lastFailed: true, pinned: true),
          _session('s-2', title: 'Normal'),
        ],
        current: '',
        online: true,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        onRename: (_, __) async {},
        onDelete: (_) async {},
        onTogglePin: (_, __) async {},
        onToggleArchive: (_, __) async {},
      ),
    );

    expect(find.textContaining('gagal'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });
}
