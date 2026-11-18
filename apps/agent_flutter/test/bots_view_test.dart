import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/bot_manager_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BotProfileItem _bot(
  String id,
  String name, {
  String persona = '',
  String? model,
  List<String> allowlist = const [],
}) =>
    BotProfileItem(
      id: id,
      name: name,
      persona: persona,
      model: model,
      greeting: 'hai',
      toolAllowlist: allowlist,
      createdAt: '2026-11-18T09:00:00.000Z',
      updatedAt: '2026-11-18T09:00:00.000Z',
    );

Widget _wrap(BotsPage page) => MaterialApp(home: Scaffold(body: page));

void main() {
  final bots = [
    _bot('helper', 'Helper', persona: 'rapih', model: 'm1'),
    _bot('scribe', 'Scribe', allowlist: ['read_file']),
  ];

  testWidgets('BotsPage menampilkan daftar bot dengan model & allowlist',
      (tester) async {
    await tester.pumpWidget(_wrap(BotsPage(
      bots: bots,
      bindings: const {'ws:lab': 'helper'},
      availableSessions: const ['ws:lab'],
      online: true,
      loading: false,
      onRefresh: null,
    )));
    await tester.pump();

    expect(find.text('Helper'), findsOneWidget);
    expect(find.text('Scribe'), findsOneWidget);
    expect(find.text('helper'), findsOneWidget);
    expect(find.textContaining('1 sesi ter-bind'), findsOneWidget);
    expect(find.textContaining('allowlist 1 tool'), findsOneWidget);
  });

  testWidgets('filter teks menyaring bot', (tester) async {
    await tester.pumpWidget(_wrap(BotsPage(
      bots: bots,
      bindings: const {},
      availableSessions: const [],
      online: true,
      loading: false,
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'scri');
    await tester.pump();

    expect(find.text('Scribe'), findsOneWidget);
    expect(find.text('Helper'), findsNothing);
  });

  testWidgets('BotsPage memanggil onRefresh saat tombol refresh ditekan',
      (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(_wrap(BotsPage(
      bots: bots,
      bindings: const {},
      availableSessions: const [],
      online: true,
      loading: false,
      onRefresh: () async => refreshed++,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(refreshed, 1);
  });

  testWidgets('dialog Create mengirim body dengan id tervalidasi',
      (tester) async {
    Map<String, dynamic>? sent;
    await tester.pumpWidget(_wrap(BotsPage(
      bots: const [],
      bindings: const {},
      availableSessions: const [],
      online: true,
      loading: false,
      onCreate: (body) async => sent = body,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Buat bot baru'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'id'), 'Bad ID!');
    await tester.enterText(find.widgetWithText(TextField, 'Nama'), 'X');
    await tester.tap(find.text('Buat'));
    await tester.pumpAndSettle();

    expect(sent, isNull);
    expect(find.textContaining('Huruf kecil/angka'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'id'), 'havier');
    await tester.tap(find.text('Buat'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!['id'], 'havier');
    expect(sent!['name'], 'X');
    expect(sent!['tool_allowlist'], isEmpty);
  });

  testWidgets('sheet binding menampilkan status sesi dan memanggil onUnbind',
      (tester) async {
    var unbound = '';
    var bound = '';
    await tester.pumpWidget(_wrap(BotsPage(
      bots: bots,
      bindings: const {'ws:lab': 'helper'},
      availableSessions: const ['ws:lab', 'ws:baru'],
      online: true,
      loading: false,
      onBind: (botId, sessionId) async {
        bound = '$botId:$sessionId';
        return true;
      },
      onUnbind: (botId, sessionId) async {
        unbound = '$botId:$sessionId';
        return true;
      },
    )));
    await tester.pump();

    expect(find.byIcon(Icons.link), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.link).first);
    await tester.pumpAndSettle();

    expect(find.text('ter-bind ke bot ini'), findsOneWidget);
    expect(find.text('belum ter-bind'), findsOneWidget);

    await tester.tap(find.text('Unbind'));
    await tester.pumpAndSettle();

    expect(unbound, 'helper:ws:lab');
    expect(bound, isEmpty);
  });
}
