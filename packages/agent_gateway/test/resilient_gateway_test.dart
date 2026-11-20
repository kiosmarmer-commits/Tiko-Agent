import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('retries outbound delivery and preserves inbound stream', () async {
    final inner = _FakeGateway(failures: 2);
    final gateway = ResilientGateway(
      inner,
      initialBackoff: Duration.zero,
      operationTimeout: const Duration(seconds: 1),
    );
    final inbound = gateway.inbound.first;
    inner.emit(
      const InboundMessage(
        channel: 'fake',
        userKey: 'u',
        sessionKey: 's',
        text: 'hello',
      ),
    );

    await gateway.send(const OutboundMessage(sessionKey: 's', text: 'reply'));
    expect(inner.sendAttempts, 3);
    expect((await inbound).text, 'hello');
  });

  test('fails after bounded attempts and closes the inner gateway', () async {
    final inner = _FakeGateway(failures: 10);
    final gateway = ResilientGateway(
      inner,
      maxAttempts: 2,
      initialBackoff: Duration.zero,
      operationTimeout: const Duration(seconds: 1),
    );

    await expectLater(
      gateway.send(const OutboundMessage(sessionKey: 's', text: 'reply')),
      throwsA(isA<StateError>()),
    );
    await gateway.close();
    expect(inner.sendAttempts, 2);
    expect(inner.closed, isTrue);
  });
}

class _FakeGateway implements Gateway {
  _FakeGateway({required this.failures});

  int failures;
  int sendAttempts = 0;
  bool closed = false;
  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'fake';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  void emit(InboundMessage message) => _inbound.add(message);

  @override
  Future<void> send(OutboundMessage message) async {
    sendAttempts++;
    if (failures > 0) {
      failures--;
      throw StateError('temporary failure');
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async {
    closed = true;
    await _inbound.close();
  }
}
