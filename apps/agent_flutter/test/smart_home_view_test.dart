import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/ui/smart_home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAgentApiClient extends AgentApiClient {
  _FakeAgentApiClient() : super(baseUrl: 'http://127.0.0.1:1', token: 'test');

  bool configured = true;
  int executeCalls = 0;
  String? lastExecutedDevice;
  Map<String, dynamic>? lastCommand;

  @override
  Future<Map<String, dynamic>> fetchSmartHomeProviders() async =>
      configured
          ? {'providers': ['home_assistant', 'tuya']}
          : throw Exception('501');

  @override
  Future<Map<String, dynamic>> fetchSmartHomeDevices({String? provider}) async {
    if (!configured) throw Exception('501');
    final all = <Map<String, dynamic>>[
      {
        'id': 'lampu-ruang-tamu',
        'name': 'Lampu Ruang Tamu',
        'provider': 'home_assistant',
        'category': 'light',
        'online': true,
        'capabilities': ['switch'],
        'state': {'on': true},
      },
      {
        'id': 'stop-kontak-1',
        'name': 'Stop Kontak',
        'provider': 'tuya',
        'category': 'switch',
        'online': false,
        'capabilities': ['switch'],
        'state': {'on': false},
      },
    ];
    return {
      'devices': [
        for (final d in all)
          if (provider == null || d['provider'] == provider) d,
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> executeSmartHome(
    String provider,
    String deviceId,
    Map<String, dynamic> command,
  ) async {
    executeCalls++;
    lastExecutedDevice = deviceId;
    lastCommand = command;
    return {'ok': true};
  }
}

Widget _wrap(SmartHomePage page) => MaterialApp(home: Scaffold(body: page));

void main() {
  testWidgets('menampilkan provider chips, perangkat, dan status online',
      (tester) async {
    final client = _FakeAgentApiClient();
    await tester.pumpWidget(
      _wrap(SmartHomePage(repo: HttpAgentRepository(client), online: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chip-provider-home_assistant')), findsOneWidget);
    expect(find.byKey(const Key('chip-provider-tuya')), findsOneWidget);
    expect(find.text('Lampu Ruang Tamu'), findsOneWidget);
    expect(find.byKey(const Key('device-home_assistant-lampu-ruang-tamu')),
        findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.textContaining('kapabilitas: switch'), findsNWidgets(2));
  });

  testWidgets('filter provider membatasi daftar perangkat', (tester) async {
    final client = _FakeAgentApiClient();
    await tester.pumpWidget(
      _wrap(SmartHomePage(repo: HttpAgentRepository(client), online: true)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chip-provider-tuya')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-tuya-stop-kontak-1')), findsOneWidget);
    expect(
      find.byKey(const Key('device-home_assistant-lampu-ruang-tamu')),
      findsNothing,
    );
  });

  testWidgets('eksekusi perangkat mengirim command ke repository',
      (tester) async {
    final client = _FakeAgentApiClient();
    await tester.pumpWidget(
      _wrap(SmartHomePage(repo: HttpAgentRepository(client), online: true)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('btn-execute-lampu-ruang-tamu')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '{"action": "on"}',
    );
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();

    expect(client.executeCalls, 1);
    expect(client.lastExecutedDevice, 'lampu-ruang-tamu');
    expect(client.lastCommand, {'action': 'on'});
    expect(find.byKey(const Key('text-smart-home-result')), findsOneWidget);
  });

  testWidgets('JSON perintah tidak valid: dialog tetap terbuka, tidak dikirim',
      (tester) async {
    final client = _FakeAgentApiClient();
    await tester.pumpWidget(
      _wrap(SmartHomePage(repo: HttpAgentRepository(client), online: true)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('btn-execute-lampu-ruang-tamu')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bukan json');
    await tester.tap(find.text('Kirim'));
    await tester.pumpAndSettle();

    expect(client.executeCalls, 0);
    expect(find.text('Eksekusi: Lampu Ruang Tamu'), findsOneWidget);
  });

  testWidgets('daemon tanpa smart-home (501): error banner + retry',
      (tester) async {
    final client = _FakeAgentApiClient()..configured = false;
    await tester.pumpWidget(
      _wrap(SmartHomePage(repo: HttpAgentRepository(client), online: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Smart home'), findsOneWidget);
    client.configured = true;
    await tester.tap(find.byTooltip('Muat ulang'));
    await tester.pumpAndSettle();
    expect(find.text('Lampu Ruang Tamu'), findsOneWidget);
  });
}
