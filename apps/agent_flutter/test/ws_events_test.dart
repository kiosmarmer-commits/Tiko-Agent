import 'dart:convert';
import 'dart:io';

import 'package:agent_flutter/agent_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server HTTP palsu dengan upgrade WebSocket di `/v1/stream` + ticket
/// `/v1/auth/ticket` untuk menguji feed event admin (GUI-P2-06).
class _FakeWsServer {
  _FakeWsServer();

  final ticketQueries = <Map<String, String>>[];
  final ticketsRequested = <String>[];
  int ticketStatus = 200;
  Future<void> Function(WebSocket ws)? onUpgrade;

  HttpServer? _server;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      if (req.uri.path == '/v1/auth/ticket') {
        ticketsRequested.add(req.method);
        req.response.statusCode = ticketStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          if (ticketStatus < 400) 'ticket': 'tk-admin' else 'error': 'no',
        }));
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/stream') {
        ticketQueries.add(req.uri.queryParameters);
        final ws = await WebSocketTransformer.upgrade(req);
        await onUpgrade?.call(ws);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
    return 'ws://127.0.0.1:${server.port}';
  }

  Future<void> close() async => _server?.close(force: true);
}

AgentApiClient _client(String wsBase) => AgentApiClient(
      baseUrl: wsBase.replaceFirst('ws://', 'http://'),
      token: 'secret-token',
    );

void main() {
  test('streamEvents hanya mengalirkan frame type=event dan memakai ticket',
      () async {
    final server = _FakeWsServer();
    final base = await server.start();
    server.onUpgrade = (ws) async {
      ws.add(jsonEncode({'type': 'typing'}));
      ws.add(jsonEncode({
        'type': 'event',
        'event': {'type': 'approval.pending', 'id': 'apr_1', 'tool': 'shell'},
      }));
      ws.add('bukan-json');
      ws.add(jsonEncode({
        'type': 'event',
        'event': {'type': 'job.completed', 'id': 'jb_1'},
      }));
      ws.add(jsonEncode({
        'type': 'event',
        'event': 'bukan-map',
      }));
      ws.add('42');
      await ws.close();
    };

    final events = await _client(base).streamEvents().toList();
    expect(events, hasLength(2));
    expect(events[0]['type'], 'approval.pending');
    expect(events[0]['id'], 'apr_1');
    expect(events[1]['type'], 'job.completed');

    expect(server.ticketsRequested, ['POST']);
    expect(server.ticketQueries.single['ticket'], 'tk-admin');
    await server.close();
    _client(base).close();
  });

  test('streamEvents: ticket gagal tetap lanjut tanpa query ticket', () async {
    final server = _FakeWsServer()..ticketStatus = 401;
    final base = await server.start();
    server.onUpgrade = (ws) async {
      ws.add(jsonEncode({
        'type': 'event',
        'event': {'type': 'model.switched'},
      }));
      await ws.close();
    };

    final events = await _client(base).streamEvents().toList();
    expect(events, hasLength(1));
    expect(server.ticketQueries.single.containsKey('ticket'), isFalse);
    await server.close();
    _client(base).close();
  });
}
