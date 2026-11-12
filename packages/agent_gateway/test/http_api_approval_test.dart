import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  late HttpClient client;
  final decisions = <({String id, bool allow})>[];
  late StreamController<Map<String, dynamic>> events;
  var shutdownRequested = false;

  setUp(() async {
    decisions.clear();
    shutdownRequested = false;
    events = StreamController<Map<String, dynamic>>.broadcast();
    server = HttpApiServer(
      onMessage: (_) async => 'ok',
      authToken: 'test-secret',
      port: 0,
      listApprovals: () async => [
        {'id': 'apr_1', 'state': 'pending'},
      ],
      decideApproval: (id, allow) async {
        decisions.add((id: id, allow: allow));
        return true;
      },
      eventStream: events.stream,
      onShutdown: () async { shutdownRequested = true; },
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await events.close();
  });

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
    final req = await client.openUrl(method, uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-secret');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final response = await req.close();
    final decoded = jsonDecode(await response.transform(utf8.decoder).join());
    expect(response.statusCode, 200);
    return Map<String, dynamic>.from(decoded as Map);
  }

  test('approval list and decisions use the supplied shared broker callback',
      () async {
    final listed = await request('GET', '/v1/approvals');
    expect((listed['approvals'] as List).single['id'], 'apr_1');

    final result = await request(
      'POST',
      '/v1/approvals/apr_1',
      body: {'approve': true},
    );
    expect(result['ok'], isTrue);
    expect(decisions.single, (id: 'apr_1', allow: true));
  });

  test('legacy chat confirmation endpoint delegates to the same callback',
      () async {
    final result = await request(
      'POST',
      '/v1/confirm',
      body: {'id': 'apr_legacy', 'allow': false},
    );
    expect(result['ok'], isTrue);
    expect(decisions.single, (id: 'apr_legacy', allow: false));
  });
  test('authenticated shutdown endpoint acknowledges and signals the daemon', () async {
    final result = await request('POST', '/v1/shutdown');
    expect(result['ok'], isTrue);
    expect(shutdownRequested, isTrue);
  });

  test('approval pending event is streamed with the broker request ID', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/v1/stream',
      headers: {'Authorization': 'Bearer test-secret'},
    );
    final received = Completer<Map<String, dynamic>>();
    final subscription = socket.listen((raw) {
      final value = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      if (value['type'] == 'confirm' && !received.isCompleted) {
        received.complete(value);
      }
    });

    events.add({
      'type': 'approval.pending',
      'id': 'apr_stream',
      'tool': 'write_file',
      'args': {'path': 'draft.txt'},
    });
    final prompt = await received.future.timeout(const Duration(seconds: 3));
    expect(prompt['id'], 'apr_stream');
    expect(prompt['prompt'], contains('write_file'));

    await socket.close();
    await subscription.cancel();
  });

}
