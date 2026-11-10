import 'dart:async';
import 'dart:convert';

import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

/// Drives [AcpAgent] with an in-memory line stream and captures output.
class _Harness {
  _Harness(AcpPromptHandler handler) {
    final input = StreamController<String>();
    agent = AcpAgent(
      handler: handler,
      input: input.stream,
      output: (line) => outputs.add(line),
    );
    this.input = input;
  }

  late final AcpAgent agent;
  late final StreamController<String> input;
  final List<String> outputs = [];

  void send(Map<String, dynamic> message) =>
      input.add(jsonEncode(message));

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

  List<Map<String, dynamic>> updates(String sessionId) => [
        for (final m in decoded)
          if (m['method'] == 'session/update' &&
              (m['params'] as Map)['sessionId'] == sessionId)
            ((m['params'] as Map)['update'] as Map)
                .cast<String, dynamic>(),
      ];

  Future<void> close() async {
    await input.close();
    await agent.serve();
  }
}

void main() {
  test('initialize returns protocol version and capabilities', () async {
    final h = _Harness((sessionId, prompt) async => 'ok');
    h.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'clientProtocolVersion': 1},
    });
    await h.close();
    final result = h.findResult(1)!;
    expect(result['protocolVersion'], 1);
    expect((result['agentCapabilities'] as Map)['loadSession'], false);
    expect((result['agentInfo'] as Map)['name'], 'tiko-agent');
  });

  test('session/new returns a session id', () async {
    final h = _Harness((sessionId, prompt) async => 'ok');
    h.send({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'session/new',
      'params': {'cwd': '/tmp'},
    });
    await h.close();
    final result = h.findResult(2)!;
    expect((result['sessionId'] as String).length, 16);
  });

  test('session/prompt streams chunks and ends with end_turn', () async {
    final received = <String>[];
    final h = _Harness((sessionId, prompt) async {
      received.add(prompt);
      return 'jawaban lengkap';
    });
    h.send({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'session/new',
    });
    h.send({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'session/prompt',
      'params': {
        'sessionId': 'abc',
        'prompt': [
          {'type': 'text', 'text': 'halo agent'},
        ],
      },
    });
    await h.close();

    expect(received, ['halo agent']);
    final result = h.findResult(4)!;
    expect(result['stopReason'], 'end_turn');

    final updates = h.updates('abc');
    expect(updates, isNotEmpty);
    expect(updates.first['sessionUpdate'], 'agent_message_chunk');
    final text = updates
        .map((u) => ((u['content'] as Map)['text'] as String? ?? ''))
        .join();
    expect(text, 'jawaban lengkap');
  });

  test('string prompt content is accepted', () async {
    var seen = '';
    final h = _Harness((sessionId, prompt) async {
      seen = prompt;
      return 'ok';
    });
    h.send({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'session/prompt',
      'params': {'sessionId': 's', 'prompt': 'prompt polos'},
    });
    await h.close();
    expect(seen, 'prompt polos');
  });

  test('session/cancel before prompt completes yields cancelled',
      () async {
    final h = _Harness((sessionId, prompt) async {
      return 'jawaban';
    });
    h.send({
      'jsonrpc': '2.0',
      'method': 'session/cancel',
      'params': {'sessionId': 's9'},
    });
    h.send({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'session/prompt',
      'params': {'sessionId': 's9', 'prompt': 'x'},
    });
    await h.close();
    expect(h.findResult(6)!['stopReason'], 'cancelled');
  });

  test('handler failure reports error update and stopReason error',
      () async {
    final h = _Harness((sessionId, prompt) async => throw StateError('boom'));
    h.send({
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'session/prompt',
      'params': {'sessionId': 'se', 'prompt': 'x'},
    });
    await h.close();
    expect(h.findResult(7)!['stopReason'], 'error');
    final updates = h.updates('se');
    expect(updates.last['sessionUpdate'], 'error');
  });

  test('unknown method returns -32601', () async {
    final h = _Harness((sessionId, prompt) async => 'ok');
    h.send({
      'jsonrpc': '2.0',
      'id': 8,
      'method': 'does/not/exist',
    });
    await h.close();
    final error = h.decoded
        .firstWhere((m) => m['id'] == 8 && m.containsKey('error'));
    expect(error['error']['code'], -32601);
  });

  test('malformed line yields parse error', () async {
    final input = StreamController<String>();
    final outputs = <String>[];
    final agent = AcpAgent(
      handler: (s, p) async => 'ok',
      input: input.stream,
      output: (line) => outputs.add(line),
    );
    input.add('{broken json');
    await input.close();
    await agent.serve();
    final error = jsonDecode(outputs.single) as Map<String, dynamic>;
    expect(error['error']['code'], -32700);
  });
}
