import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// DAG run team (Fase E5) di atas fake agentd: laporan `/v1/teams/runs`
/// terbaca oleh repository dengan bearer token.
void main() {
  test('teamRuns() membaca daftar laporan + meneruskan bearer', () async {
    final fake = _ApiServer();
    final client = AgentApiClient(baseUrl: await fake.start(), token: 't');
    final repo = HttpAgentRepository(client);
    addTearDown(client.close);
    addTearDown(() => fake.close());

    final reports = await repo.teamRuns();
    expect(reports, hasLength(2));
    expect(reports.first['run_id'], 'r-team-2');
    expect((reports.first['plan'] as List), hasLength(3));
    expect(fake.lastAuthHeader, 'Bearer t');
  });

  test('teamRuns() dalam kosong atau error transport tetap terjawab', () async {
    final fake = _ApiServer();
    final client = AgentApiClient(baseUrl: await fake.start(), token: 't');
    final repo = HttpAgentRepository(client);
    addTearDown(client.close);
    addTearDown(() => fake.close());

    fake.runs = <Map<String, dynamic>>[];
    expect(await repo.teamRuns(), isEmpty);
  });
}

class _ApiServer {
  HttpServer? _server;
  String lastAuthHeader = '';

  List<Map<String, dynamic>> runs = [
    {
      'run_id': 'r-team-2',
      'team_id': 'duo',
      'goal': 'Perbaiki linter',
      'success': true,
      'plan_source': 'planner',
      'plan': [
        {'id': 't1', 'prompt': 'scan', 'agent_id': 'planner-1', 'depends_on': []},
        {
          'id': 't2',
          'prompt': 'fix',
          'agent_id': 'coder-1',
          'depends_on': ['t1'],
        },
        {
          'id': 't3',
          'prompt': 'verify',
          'agent_id': 'reviewer-1',
          'depends_on': ['t1', 't2'],
        },
      ],
      'nodes': [
        {'node_id': 't1', 'agent_id': 'planner-1', 'ok': true, 'output': 'x'},
        {'node_id': 't2', 'agent_id': 'coder-1', 'ok': true, 'output': 'y'},
        {'node_id': 't3', 'agent_id': 'reviewer-1', 'ok': true, 'output': 'z'},
      ],
      'synthesis': 'semua selesai',
      'tokens_used': 4321,
      'tool_call_count': 5,
    },
    {
      'run_id': 'r-team-1',
      'goal': 'gagal kasus',
      'success': false,
      'plan_source': 'fallback',
      'plan': [
        {'id': 'a', 'prompt': 'satu', 'depends_on': []},
      ],
      'nodes': [
        {'node_id': 'a', 'agent_id': 'coder-1', 'ok': false, 'error': 'timeout'},
      ],
      'synthesis': '',
    },
  ];

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        if (path == '/v1/teams/runs') {
          lastAuthHeader = req.headers.value('authorization') ?? '';
          req.response.write(jsonEncode(<String, dynamic>{'runs': runs}));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{'ok': false}));
        }
        await req.response.close();
      }
    }());
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
