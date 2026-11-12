import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('signal: receive envelope -> inbound; send posts JSON-RPC', () async {
    final requests = <Map<String, dynamic>>[];
    var receiveCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sessions = StreamController<HttpRequest>();
    server.listen(sessions.add, onError: sessions.addError);
    unawaited(() async {
      await for (final req in sessions.stream) {
        final body = await utf8.decoder.bind(req).join();
        requests.add(jsonDecode(body) as Map<String, dynamic>);
        final method = requests.last['method']?.toString() ?? '';
        if (method == 'receive') receiveCount += 1;
        final payload = method == 'receive' && receiveCount == 1
            ? jsonEncode({
                'jsonrpc': '2.0',
                'id': requests.last['id'],
                'result': [
                  {
                    'envelope': {
                      'source': '+628123456789',
                      'dataMessage': {'message': 'halo tiko', 'timestamp': 123},
                    },
                  },
                  {
                    'envelope': {
                      'source': '+629999999999',
                      'dataMessage': {'message': 'banned', 'timestamp': 124},
                    },
                  },
                ],
              })
            : jsonEncode({'jsonrpc': '2.0', 'id': requests.last['id'], 'result': []});
        req.response.headers.contentType = ContentType.json;
        req.response.write(payload);
        await req.response.close();
      }
    }());
    addTearDown(() async {
      await sessions.close();
      await server.close(force: true);
    });

    final gw = SignalGateway(
      rpcUrl: 'http://127.0.0.1:${server.port}',
      account: '+628000000000',
      allowedSenders: {'+628123456789'},
      pollTimeoutSec: 1,
    );
    final received = <InboundMessage>[];
    final sub = gw.inbound.listen(received.add);
    await gw.start();

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(received, hasLength(1));
    expect(received.first.channel, 'signal');
    expect(received.first.userKey, '+628123456789');
    expect(received.first.sessionKey, 'signal:+628123456789');
    expect(received.first.text, 'halo tiko');

    await gw.send(
      const OutboundMessage(sessionKey: 'signal:+628123456789', text: 'balasan'),
    );
    await gw.sendTyping('signal:+628123456789');

    final sendCalls =
        requests.where((r) => r['method'] == 'send').toList();
    expect(sendCalls, hasLength(1));
    expect(sendCalls.first['params']['recipient'], '+628123456789');
    expect(sendCalls.first['params']['message'], 'balasan');
    expect(sendCalls.first['params']['account'], '+628000000000');

    await sub.cancel();
    await gw.close();
  });

  test('signal: send menolak sessionKey asing', () async {
    final gw = SignalGateway(
      rpcUrl: 'http://127.0.0.1:1',
      account: '+628000000000',
      allowedSenders: {'+628123456789'},
    );
    await expectLater(
      gw.send(const OutboundMessage(sessionKey: 'telegram:123', text: 'x')),
      throwsArgumentError,
    );
    await gw.close();
  });
}
