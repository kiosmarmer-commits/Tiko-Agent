import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  test('matrix: sync events -> inbound; send PUT dengan txn unik', () async {
    final requests = <HttpRequest>[];
    final bodies = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sessions = StreamController<HttpRequest>();
    var syncCount = 0;
    server.listen(sessions.add, onError: sessions.addError);
    unawaited(() async {
      await for (final req in sessions.stream) {
        final body = await utf8.decoder.bind(req).join();
        requests.add(req);
        bodies.add(body);
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.contains('/sync')) {
          syncCount += 1;
          final since = req.uri.queryParameters['since'];
          final events = since == null
              ? []
              : [
                  {
                    'type': 'm.room.message',
                    'event_id': '\$ev1',
                    'sender': '@alice:example.org',
                    'content': {'msgtype': 'm.text', 'body': 'halo matrix'},
                  },
                  {
                    'type': 'm.room.message',
                    'event_id': '\$ev1',
                    'sender': '@alice:example.org',
                    'content': {'msgtype': 'm.text', 'body': 'dup'},
                  },
                ];
          req.response.write(jsonEncode({
            'next_batch': 's$syncCount',
            'rooms': {
              'join': {
                '!room1:example.org': {
                  'timeline': {'events': events},
                },
                '!room2:example.org': {
                  'timeline': {
                    'events': [
                      {
                        'type': 'm.room.message',
                        'event_id': '\$ev3',
                        'sender': '@bob:example.org',
                        'content': {'msgtype': 'm.text', 'body': 'ruang lain'},
                      },
                    ],
                  },
                },
              },
            },
          }));
        } else {
          req.response.write(jsonEncode({'event_id': '\$sent1'}));
        }
        await req.response.close();
      }
    }());
    addTearDown(() async {
      await sessions.close();
      await server.close(force: true);
    });

    final gw = MatrixGateway(
      homeserverUrl: 'http://127.0.0.1:${server.port}',
      accessToken: 'syt_test',
      allowedRooms: {'!room1:example.org'},
      syncTimeoutMs: 100,
    );
    final received = <InboundMessage>[];
    final sub = gw.inbound.listen(received.add);
    await gw.start();

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(received, hasLength(1));
    expect(received.first.channel, 'matrix');
    expect(received.first.userKey, '@alice:example.org');
    expect(received.first.sessionKey, 'matrix:!room1:example.org');
    expect(received.first.text, 'halo matrix');

    await gw.send(
      const OutboundMessage(sessionKey: 'matrix:!room1:example.org', text: 'balasan'),
    );
    await gw.sendTyping('matrix:!room1:example.org');

    final puts = requests.where((r) => r.method == 'PUT').toList();
    final sendPuts = puts
        .where((r) => r.uri.path.contains('/send/m.room.message/'))
        .toList();
    expect(sendPuts, hasLength(1));
    final txnId = sendPuts.first.uri.pathSegments.last;
    expect(txnId, startsWith('tiko-'));
    final sendBody = bodies.firstWhere((b) => b.contains('balasan'));
    expect(jsonDecode(sendBody), {'msgtype': 'm.text', 'body': 'balasan'});
    expect(
      requests.first.headers.value('Authorization'),
      'Bearer syt_test',
    );

    await sub.cancel();
    await gw.close();
  });

  test('matrix: send menolak sessionKey asing', () async {
    final gw = MatrixGateway(
      homeserverUrl: 'http://127.0.0.1:1',
      accessToken: 'syt_test',
      allowedRooms: {'!room1:example.org'},
    );
    await expectLater(
      gw.send(const OutboundMessage(sessionKey: 'signal:+628', text: 'x')),
      throwsArgumentError,
    );
    await gw.close();
  });
}
