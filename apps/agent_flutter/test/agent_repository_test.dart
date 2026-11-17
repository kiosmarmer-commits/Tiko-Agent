import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/data/agent_repository.dart';
import 'package:agent_flutter/data/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server palsu dengan error model typed (GUI-P0-03).
class _ApiServer {
  final paths = <String>[];
  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(() async {
      await for (final req in server) {
        final path = req.uri.path;
        paths.add(path);
        req.response.headers.contentType = ContentType.json;
        if (path == '/v1/sessions') {
          req.response.write(jsonEncode(<String, dynamic>{
            'sessions': [
              {
                'id': 'flutter:default',
                'title': 'Default',
                'channel': 'flutter',
                'updated_at': '2026-11-18T10:00:00Z',
                'turns': 4,
              },
              {'id': 'http:abc', 'turns': 1.0},
            ],
          }));
        } else if (path.startsWith('/v1/sessions/') &&
            path.endsWith('/messages')) {
          if (path.contains('tidak-ada')) {
            req.response.statusCode = 404;
            req.response.write(jsonEncode(<String, dynamic>{
              'ok': false,
              'code': 'not_found',
              'error': 'session not found',
              'retryable': false,
            }));
            await req.response.close();
            continue;
          }
          req.response.write(jsonEncode(<String, dynamic>{
            'session_id': 'flutter:default',
            'messages': [
              {'role': 'user', 'content': 'halo'},
              {'role': 'assistant', 'content': 'hai juga', 'at': '2026-11-18T10:01:00Z'},
            ],
          }));
        } else if (path == '/v1/approvals') {
          req.response.write(jsonEncode(<String, dynamic>{
            'approvals': [
              {'id': 'apr_1', 'tool': 'write_file', 'risk': 'high', 'state': 'pending'},
              {'id': 'apr_2', 'tool': 'search', 'state': 'approved', 'actor': 'ui'},
            ],
          }));
        } else if (path == '/v1/memories') {
          req.response.write(jsonEncode(<String, dynamic>{
            'memories': [
              {'id': 'm1', 'text': 'fakta satu', 'kind': 'fact'},
            ],
          }));
        } else if (path == '/v1/events') {
          req.response.write(jsonEncode(<String, dynamic>{
            'events': [
              {'type': 'run.completed', 'at': '2026-11-18T10:02:00Z'},
            ],
          }));
        } else {
          req.response.statusCode = 404;
          req.response.write(jsonEncode(<String, dynamic>{
            'ok': false,
            'code': 'not_found',
            'error': 'not found',
            'retryable': false,
          }));
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

void main() {
  late _ApiServer fake;
  late AgentApiClient client;
  late HttpAgentRepository repo;

  setUp(() async {
    fake = _ApiServer();
    final base = await fake.start();
    client = AgentApiClient(baseUrl: base, token: 't');
    repo = HttpAgentRepository(client);
  });

  tearDown(() async {
    client.close();
    await fake.close();
  });

  test('sessions() mengembalikan List<SessionSummary> typed', () async {
    final sessions = await repo.sessions();
    expect(sessions, hasLength(2));
    expect(sessions[0].id, 'flutter:default');
    expect(sessions[0].displayTitle, 'Default');
    expect(sessions[0].turns, 4);
    expect(sessions[1].displayTitle, 'http:abc');
    expect(sessions[1].turns, 1);
    expect(sessions[1].title, isEmpty);
  });

  test('sessionMessages() mengembalikan List<SessionMessage> typed',
      () async {
    final messages = await repo.sessionMessages('flutter:default');
    expect(messages.map((m) => '${m.role}:${m.content}').toList(),
        ['user:halo', 'assistant:hai juga']);
    expect(messages[1].at, '2026-11-18T10:01:00Z');
  });

  test('approvals()/memories()/events() typed dengan helper isPending',
      () async {
    final approvals = await repo.approvals();
    expect(approvals.first.isPending, true);
    expect(approvals.last.isPending, false);
    expect(approvals.last.actor, 'ui');

    final memories = await repo.memories();
    expect(memories.single.text, 'fakta satu');
    expect(memories.single.kind, 'fact');

    final events = await repo.events();
    expect(events.single.type, 'run.completed');
    expect(events.single.at, '2026-11-18T10:02:00Z');
  });

  test('error HTTP dari daemon menjadi ApiError typed', () async {
    try {
      await repo.sessionMessages('flutter:tidak-ada');
      fail('harusnya melempar');
    } on ApiError catch (e) {
      expect(e.code, ApiErrorCode.notFound);
      expect(e.statusCode, 404);
    }
  });

  test('kegagalan transport menjadi ApiError.network', () async {
    final dead = ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = (await dead).port;
    await (await dead).close();
    final offline = HttpAgentRepository(
      AgentApiClient(baseUrl: 'http://127.0.0.1:$port', token: 't'),
    );
    try {
      await offline.sessions();
      fail('harusnya melempar');
    } on ApiError catch (e) {
      expect(e.code, ApiErrorCode.network);
      expect(e.retryable, true);
    }
  });
}
