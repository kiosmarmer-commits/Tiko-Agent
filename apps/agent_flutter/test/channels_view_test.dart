import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/channels_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ChannelsPage page) => MaterialApp(home: Scaffold(body: page));

const _snapshot = ChannelsSnapshot(
  channels: [
    ChannelInfo(channel: 'telegram', active: true, env: ['TG_TOKEN', 'TG_ALLOW']),
    ChannelInfo(channel: 'discord', active: false,
        env: ['DISCORD_BOT_TOKEN', 'DISCORD_ALLOW']),
    ChannelInfo(channel: 'http', active: true),
  ],
);

void main() {
  testWidgets('menampilkan channel, badge aktif/nonaktif, dan nama env',
      (tester) async {
    await tester.pumpWidget(_wrap(const ChannelsPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('telegram'), findsOneWidget);
    expect(find.text('discord'), findsOneWidget);
    expect(find.text('aktif'), findsNWidgets(2));
    expect(find.text('nonaktif'), findsOneWidget);
    expect(find.text('env TG_TOKEN'), findsOneWidget);
    expect(find.text('env DISCORD_BOT_TOKEN'), findsOneWidget);
  });

  testWidgets('menampilkan kartu penjelasan setup via env + restart',
      (tester) async {
    await tester.pumpWidget(_wrap(const ChannelsPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Setup'), findsOneWidget);
    expect(find.textContaining('read-only'), findsOneWidget);
  });

  testWidgets('kondisi kosong: snapshot null menampilkan pesan',
      (tester) async {
    await tester.pumpWidget(_wrap(const ChannelsPage(
      snapshot: null,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Belum ada data channel.'), findsOneWidget);
  });

  testWidgets('tombol refresh memanggil onRefresh', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(_wrap(ChannelsPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onRefresh: () async => refreshed++,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(refreshed, 1);
  });
}
