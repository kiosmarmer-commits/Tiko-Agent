import 'package:agent_flutter/data/models.dart';
import 'package:agent_flutter/ui/plugin_manager_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(PluginManagerPage page) => MaterialApp(home: Scaffold(body: page));

const _snapshot = PluginsToolsSnapshot(
  plugins: [
    PluginItem(
      id: 'memory-secretary',
      registered: true,
      granted: ['memory.write'],
    ),
    PluginItem(
      id: 'weather-pro',
      pending: true,
      requested: ['tools.register', 'network.fetch'],
    ),
  ],
  tools: [
    ToolInfo(
      name: 'read_file',
      description: 'Baca file',
      risk: 'low',
      timeoutSec: 30,
      parallelSafe: true,
    ),
    ToolInfo(
      name: 'shell_exec',
      description: 'Eksekusi shell',
      risk: 'critical',
      timeoutSec: 60,
    ),
  ],
  events: [
    PluginEventInfo(plugin: 'weather-pro', hook: 'onSessionStart',
        detail: 'consent required', at: '2026-11-18T00:00:00.000Z'),
  ],
  mcp: McpStatusInfo(
    started: true,
    configured: [
      McpServerInfo(
        id: 'fs-mcp',
        type: 'stdio',
        enabled: true,
        risk: 'medium',
        command: '/usr/bin/fs-mcp',
      ),
    ],
    loader: [
      {'id': 'fs-mcp', 'status': 'ready', 'transport': 'stdio', 'tools': 2},
    ],
  ),
);

void main() {
  testWidgets('menampilkan plugin, badge status, dan permission chips',
      (tester) async {
    await tester.pumpWidget(_wrap(const PluginManagerPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('memory-secretary'), findsOneWidget);
    expect(find.text('weather-pro'), findsOneWidget);
    expect(find.text('terdaftar'), findsOneWidget);
    expect(find.text('menunggu consent'), findsOneWidget);
    expect(find.textContaining('memory.write'), findsOneWidget);
    expect(find.textContaining('diminta\u00b7tools.register'), findsOneWidget);
  });

  testWidgets('menampilkan katalog tool + badge risk dan server MCP',
      (tester) async {
    await tester.pumpWidget(_wrap(const PluginManagerPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Tools terdaftar (2)'), findsOneWidget);
    expect(find.text('read_file'), findsOneWidget);
    expect(find.text('shell_exec'), findsOneWidget);
    expect(find.text('critical'), findsOneWidget);
    expect(find.textContaining('Server MCP (1)'), findsOneWidget);
    expect(find.text('fs-mcp (stdio)'), findsOneWidget);
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('kondisi kosong: snapshot null menampilkan pesan',
      (tester) async {
    await tester.pumpWidget(_wrap(const PluginManagerPage(
      snapshot: null,
      online: true,
      loading: false,
    )));
    await tester.pump();

    expect(find.text('Belum ada data plugin.'), findsOneWidget);
  });

  testWidgets('tombol Setujui memanggil onConsent grant + snackbar',
      (tester) async {
    var consented = '';
    await tester.pumpWidget(_wrap(PluginManagerPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onConsent: (plugin, action) async {
        consented = '$plugin:$action';
        return 'Plugin "$plugin" disetujui dan terdaftar.';
      },
    )));
    await tester.pump();

    await tester.tap(find.text('Setujui'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(consented, 'weather-pro:grant');
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('disetujui'), findsOneWidget);
  });

  testWidgets('tombol Cabut consent memanggil onConsent revoke',
      (tester) async {
    var consented = '';
    await tester.pumpWidget(_wrap(PluginManagerPage(
      snapshot: _snapshot,
      online: true,
      loading: false,
      onConsent: (plugin, action) async {
        consented = '$plugin:$action';
        return 'Consent plugin "$plugin" dicabut.';
      },
    )));
    await tester.pump();

    await tester.tap(find.text('Cabut consent'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(consented, 'memory-secretary:revoke');
  });
}
