import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

class _EchoTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'echo',
        description: 'low-risk echo',
        inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async =>
      const ToolResult(callId: '', content: 'echo-ok');
}

class _DangerTool implements Tool {
  @override
  ToolSpec get spec => const ToolSpec(
        name: 'danger',
        description: 'high-risk tool',
        inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
        risk: 'high',
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async =>
      const ToolResult(callId: '', content: 'danger-ok');
}

/// Fake MCP HTTP server: exposes `srv_echo`/`srv_danger` on tools/list, then
/// sends a server-initiated `tools/list` request over GET SSE and records the
/// JSON-RPC responses POSTed back by the client (C2).
class _WiringServer {
  late HttpServer server;
  late String baseUrl;
  final responses = <Map<String, dynamic>>[];
  final _responseReceived = StreamController<void>.broadcast();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      if (req.method == 'GET') {
        req.response.bufferOutput = false;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        req.response.write(
          'id: srv-ev-1\ndata: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': 'srv-0',
            'method': 'tools/list',
          })}\n\n',
        );
        await req.response.flush();
        return;
      }
      final body = await utf8.decodeStream(req);
      final msg = body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
      final method = msg['method'] as String?;
      if (method == 'initialize') {
        req.response.headers.set('mcp-session-id', 'sess-wiring');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': msg['id'],
          'result': {
            'protocolVersion': msg['params']['protocolVersion'],
            'serverInfo': {'name': 'mock-wiring'},
          },
        }));
        await req.response.close();
        return;
      }
      if (method == 'tools/list') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': msg['id'],
          'result': {
            'tools': [
              {'name': 'srv_echo', 'description': 'server echo'},
              {'name': 'srv_danger', 'description': 'server danger'},
            ],
          },
        }));
        await req.response.close();
        return;
      }
      if (method == null && msg.containsKey('id')) {
        responses.add(msg);
        _responseReceived.add(null);
      }
      req.response.statusCode = 202;
      await req.response.close();
    });
  }

  Future<void> waitResponses(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (responses.length < count && DateTime.now().isBefore(deadline)) {
      await _responseReceived.stream.first
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await _responseReceived.close();
  }
}

void main() {
  test('answerServerRequests: request tools/list dari server dijawab dan '
      'hanya tool low-risk yang terekspos (C2)', () async {
    final srv = _WiringServer();
    await srv.start();

    final registry = ToolRegistry()
      ..register(_EchoTool())
      ..register(_DangerTool());
    final loader = McpToolLoader(
      registry,
      sandbox: SandboxRunner(),
      answerServerRequests: true,
    );
    addTearDown(srv.close);

    final loaded = await loader.loadServers([
      {
        'id': 'wiring',
        'type': 'http',
        'url': srv.baseUrl,
        'allow': ['srv_echo'],
        'risk': 'medium',
      },
    ]);
    expect(loaded, 1);

    await srv.waitResponses(1);
    final resp = srv.responses.single;
    expect(resp['id'], 'srv-0');
    final tools = (resp['result']['tools'] as List)
        .cast<Map<String, dynamic>>()
        .map((t) => t['name'])
        .toList();
    expect(tools, contains('echo'));
    expect(tools, isNot(contains('danger')),
        reason: 'hanya tool berisiko low yang boleh dijawab ke server');
  });

  test('default (flag off): request server tidak dijawab (fail-closed)',
      () async {
    final srv = _WiringServer();
    await srv.start();

    final registry = ToolRegistry()..register(_EchoTool());
    final loader = McpToolLoader(registry, sandbox: SandboxRunner());
    addTearDown(srv.close);

    final loaded = await loader.loadServers([
      {
        'id': 'wiring',
        'type': 'http',
        'url': srv.baseUrl,
        'allow': ['srv_echo'],
        'risk': 'medium',
      },
    ]);
    expect(loaded, 1);

    await Future<void>.delayed(const Duration(seconds: 2));
    expect(srv.responses, isEmpty,
        reason: 'tanpa opt-in, request server hanya dicatat');
  });
}
