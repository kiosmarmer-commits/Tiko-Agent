import 'dart:convert';

import 'package:agent_tools/agent_tools.dart';
import 'package:agent_tools/src/ide_integration.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('openai_api: apiKey kosong menolak semua route (fail-closed)', () async {
    final server = OpenAiCompatServer(
      config: const OpenAiCompatConfig(apiKey: ''),
      handler: (req) async => 'tidak boleh tercapai',
    );
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final res = await http.post(
      base.replace(path: '/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer ',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'tiko-agent',
        'messages': [
          {'role': 'user', 'content': 'halo'},
        ],
      }),
    );
    expect(res.statusCode, 401);
    expect(jsonDecode(res.body)['error']['type'], 'authentication_error');
    await server.stop();
  });

  test('openai_api: token salah ditolak, token benar diterima', () async {
    final server = OpenAiCompatServer(
      config: const OpenAiCompatConfig(apiKey: 'secret-key-abc'),
      handler: (req) async => 'ok',
    );
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');

    final wrong = await http.get(
      base.replace(path: '/v1/models'),
      headers: {'Authorization': 'Bearer secret-key-abd'},
    );
    expect(wrong.statusCode, 401);

    final right = await http.get(
      base.replace(path: '/v1/models'),
      headers: {'Authorization': 'Bearer secret-key-abc'},
    );
    expect(right.statusCode, 200);
    await server.stop();
  });

  test('ACP: token dikonfigurasi — tanpa/wrong token ditolak 401', () async {
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(
        enableAcp: true,
        acpPort: 0,
        acpHost: '127.0.0.1',
        acpAuthToken: 'acp-secret-token',
        autoDetect: false,
        registerCommands: false,
      ),
    );
    await manager.start();
    final base = Uri.parse('http://127.0.0.1:${manager.acpPort}');

    final noAuth = await http.post(base, body: '{}');
    expect(noAuth.statusCode, 401);

    final wrong = await http.post(
      base,
      headers: {'Authorization': 'Bearer acp-secret-wrong'},
      body: '{}',
    );
    expect(wrong.statusCode, 401);

    await manager.stop();
  });

  test('ACP: token benar melewati auth (invalid JSON -> 400, bukan 401)',
      () async {
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(
        enableAcp: true,
        acpPort: 0,
        acpHost: '127.0.0.1',
        acpAuthToken: 'acp-secret-token',
        autoDetect: false,
        registerCommands: false,
      ),
    );
    await manager.start();
    final base = Uri.parse('http://127.0.0.1:${manager.acpPort}');

    final ok = await http.post(
      base,
      headers: {'Authorization': 'Bearer acp-secret-token'},
      body: 'bukan json',
    );
    expect(ok.statusCode, 400);

    await manager.stop();
  });

  test('ACP: tanpa token (default loopback) auth terbuka', () async {
    final manager = IdeIntegrationManager(
      config: const IdeIntegrationConfig(
        enableAcp: true,
        acpPort: 0,
        acpHost: '127.0.0.1',
        autoDetect: false,
        registerCommands: false,
      ),
    );
    await manager.start();
    final base = Uri.parse('http://127.0.0.1:${manager.acpPort}');

    final res = await http.post(base, body: 'bukan json');
    expect(res.statusCode, 400);

    await manager.stop();
  });
}
