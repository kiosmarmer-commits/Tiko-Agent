import 'dart:async';
import 'dart:convert';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Drives [McpAgent] with an in-memory line stream and captures output.
class _Harness {
  _Harness({
    required String serverName,
    required String serverVersion,
    required List<McpAgentTool> tools,
  }) {
    final input = StreamController<String>();
    agent = McpAgent(
      serverName: serverName,
      serverVersion: serverVersion,
      tools: tools,
      input: input.stream,
      output: (line) => outputs.add(line),
    );
    this.input = input;
  }

  late final McpAgent agent;
  late final StreamController<String> input;
  final List<String> outputs = [];

  void send(Map<String, dynamic> message) => input.add(jsonEncode(message));

  void sendRaw(String line) => input.add(line);

  List<Map<String, dynamic>> get decoded => [
        for (final line in outputs)
          jsonDecode(line) as Map<String, dynamic>,
      ];

  Map<String, dynamic>? findResult(Object id) {
    for (final m in decoded) {
      if (m['id'] == id && m.containsKey('result')) {
        return m['result'] as Map<String, dynamic>;
      }
    }
    return null;
  }

  Map<String, dynamic>? findError(Object id) {
    for (final m in decoded) {
      if (m['id'] == id && m.containsKey('error')) {
        return m['error'] as Map<String, dynamic>;
      }
    }
    return null;
  }

  Future<void> close() async {
    // Subscribe before closing the input: awaiting close() first would
    // deadlock because the done event needs a listener to be delivered.
    final serving = agent.serve();
    await input.close();
    await serving;
  }
}

void main() {
  test('initialize returns protocolVersion, capabilities and serverInfo', () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: const [],
    );
    h.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-03-26',
        'clientInfo': {'name': 'claude', 'version': '1.0'},
      },
    });
    await h.close();
    final result = h.findResult(1)!;
    expect(result['protocolVersion'], '2025-03-26');
    expect((result['capabilities'] as Map)['tools'], isA<Map>());
    final info = result['serverInfo'] as Map;
    expect(info['name'], 'tiko-agent');
    expect(info['version'], '0.2.0');
  });

  test('initialize falls back to default protocolVersion on unknown request',
      () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: const [],
    );
    h.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '9999-01-01'},
    });
    await h.close();
    expect(h.findResult(1)!['protocolVersion'], '2024-11-05');
  });

  test('tools/list exposes name, description and inputSchema', () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: [
        McpAgentTool(
          name: 'tiko_chat',
          description: 'chat penuh',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
          handler: (_) async => const McpToolResult(text: 'ok'),
        ),
      ],
    );
    h.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    await h.close();
    final result = h.findResult(2)!;
    final tools = result['tools'] as List;
    expect(tools, hasLength(1));
    final tool = tools.first as Map;
    expect(tool['name'], 'tiko_chat');
    expect(tool['description'], 'chat penuh');
    expect((tool['inputSchema'] as Map)['type'], 'object');
  });

  test('tools/call returns text content and isError from the handler',
      () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: [
        McpAgentTool(
          name: 'fail_always',
          description: 'gagal',
          inputSchema: {'type': 'object', 'properties': {}},
          handler: (_) async =>
              const McpToolResult(text: 'masalah', isError: true),
        ),
      ],
    );
    h.send({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'fail_always', 'arguments': {}},
    });
    await h.close();
    final result = h.findResult(3)!;
    final content = result['content'] as List;
    expect(content, hasLength(1));
    expect((content.first as Map)['type'], 'text');
    expect((content.first as Map)['text'], 'masalah');
    expect(result['isError'], true);
  });

  test('tools/call unknown tool and throwing handler are isError results',
      () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: [
        McpAgentTool(
          name: 'boom',
          description: 'melempar',
          inputSchema: {'type': 'object', 'properties': {}},
          handler: (_) async => throw StateError('ledak'),
        ),
      ],
    );
    h.send({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {'name': 'tidak_ada', 'arguments': {}},
    });
    h.send({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'tools/call',
      'params': {'name': 'boom', 'arguments': {}},
    });
    await h.close();
    final unknown = h.findResult(4)!;
    expect(unknown['isError'], true);
    expect(
      ((unknown['content'] as List).first as Map)['text'],
      contains('Tool tidak dikenal: tidak_ada'),
    );
    final thrown = h.findResult(5)!;
    expect(thrown['isError'], true);
    expect(
      ((thrown['content'] as List).first as Map)['text'],
      contains('Tool boom gagal'),
    );
  });

  test('ping returns empty result; unknown method yields -32601', () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: const [],
    );
    h.send({'jsonrpc': '2.0', 'id': 6, 'method': 'ping'});
    h.send({'jsonrpc': '2.0', 'id': 7, 'method': 'tidak/ada'});
    await h.close();
    expect(h.findResult(6), {});
    final err = h.findError(7)!;
    expect(err['code'], -32601);
  });

  test('notifications produce no output; invalid JSON yields -32700',
      () async {
    final h = _Harness(
      serverName: 'tiko-agent',
      serverVersion: '0.2.0',
      tools: const [],
    );
    h.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    h.send({'jsonrpc': '2.0', 'method': 'notifications/cancelled'});
    h.sendRaw('bukan json');
    await h.close();
    final errs = [
      for (final m in h.decoded)
        if (m.containsKey('error')) m['error'] as Map,
    ];
    expect(errs, hasLength(1));
    expect(errs.first['code'], -32700);
  });
}
