import 'package:agent_flutter/agent_api_client.dart';
import 'package:agent_flutter/ui/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAgentApiClient extends AgentApiClient {
  _FakeAgentApiClient() : super(baseUrl: 'http://127.0.0.1:1', token: 'test');

  int sendMessageCalls = 0;
  final decisions = <({String id, bool allow})>[];
  bool failDecision = false;
  Stream<Map<String, dynamic>> Function(String text)? streamHandler;

  @override
  Stream<Map<String, dynamic>> streamChat(
    String text, {
    String sessionKey = 'flutter:default',
  }) => streamHandler?.call(text) ?? const Stream.empty();

  @override
  Future<String> sendMessage(
    String text, {
    String sessionKey = 'flutter:default',
  }) async {
    sendMessageCalls++;
    return 'fallback reply';
  }

  @override
  Future<bool> decideApproval(String id, bool approve) async {
    if (failDecision) throw StateError('network unavailable');
    decisions.add((id: id, allow: approve));
    return true;
  }
}

void main() {
  test('WebSocket failure does not replay the prompt over HTTP', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        throw StateError('connection dropped after send');
      };
    final controller = ChatController(client);
    addTearDown(controller.dispose);

    await controller.send('buat file');

    expect(client.sendMessageCalls, 0);
    expect(controller.messages.last['text'], contains('connection dropped'));
  });

  test('approval decided in another UI surface clears the chat prompt', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_123', 'prompt': 'Izinkan write_file?'};
        yield {
          'type': 'event',
          'event': {'type': 'approval.decided', 'id': 'apr_123', 'state': 'approved'},
        };
        yield {'type': 'done'};
      };
    final controller = ChatController(client);
    addTearDown(controller.dispose);

    await controller.send('buat file');

    expect(controller.pendingConfirm, isNull);
    expect(controller.messages.where((message) => message['role'] == 'system'), isEmpty);
  });

  test('approval stays visible after a network error so the user can retry', () async {
    final client = _FakeAgentApiClient()
      ..failDecision = true
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_retry', 'prompt': 'Izinkan write_file?'};
      };
    final controller = ChatController(client);
    addTearDown(controller.dispose);

    await controller.send('buat file');
    await controller.respondConfirm(true);

    expect(controller.pendingConfirm?.id, 'apr_retry');
  });

  test('chat approval sends the broker request ID to the API', () async {
    final client = _FakeAgentApiClient()
      ..streamHandler = (_) async* {
        yield {'type': 'confirm', 'id': 'apr_456', 'prompt': 'Izinkan write_file?'};
      };
    final controller = ChatController(client);
    addTearDown(controller.dispose);

    await controller.send('buat file');
    await controller.respondConfirm(true);

    expect(client.decisions, [(id: 'apr_456', allow: true)]);
    expect(controller.pendingConfirm, isNull);
  });
}
