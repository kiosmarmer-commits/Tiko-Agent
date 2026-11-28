import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> sendBodies;
  var mentionsPayload = <String, dynamic>{};

  setUp(() async {
    sendBodies = [];
    mentionsPayload = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path.contains('/mentions')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(mentionsPayload));
      } else if (req.uri.path.endsWith('/tweets')) {
        sendBodies.add({
          'body': body,
          'auth': req.headers.value('Authorization') ?? '',
        });
        req.response.statusCode = 201;
        req.response.write(jsonEncode({'data': {'id': '999'}}));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
    });
  });

  XGateway gateway({required Set<String> allow}) => XGateway(
        bearerToken: 'test-bearer',
        botUserId: '123',
        allowedUserIds: allow,
        apiBase: 'http://127.0.0.1:${server.port}',
        pollIntervalSec: 1,
      );

  test(
      'X-1: mentions → inbound dengan allowlist + dedupe + since_id progresif',
      () async {
    mentionsPayload = {
      'data': [
        {
          'id': '100',
          'text': '@bot halo',
          'author_id': '42',
          'conversation_id': '100',
        },
        {
          'id': '101',
          'text': '@bot dari penyusup',
          'author_id': '999',
          'conversation_id': '101',
        },
      ],
      'meta': {'newest_id': '101'},
    };
    final gw = gateway(allow: {'42'});
    final received = <InboundMessage>[];
    final sub = gw.inbound.listen(received.add);
    await gw.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    mentionsPayload = {
      'data': [
        {
          'id': '100',
          'text': '@bot halo (dup)',
          'author_id': '42',
          'conversation_id': '100',
        },
        {
          'id': '102',
          'text': '@bot lagi',
          'author_id': '42',
          'conversation_id': '102',
        },
      ],
    };
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await gw.stop();
    await sub.cancel();

    expect(received.length, 2, reason: 'penyusup didrop + dup didedupe');
    expect(received[0].channel, 'x');
    expect(received[0].userKey, 'x:42');
    expect(received[0].sessionKey, 'x:100');
    expect(received[0].meta['tweet_id'], '100');
    expect(received[1].meta['tweet_id'], '102');
  });

  test('X-2: send balasan memakai in_reply_to_tweet_id dan clip 280',
      () async {
    final gw = gateway(allow: {'42'});
    final longText = 'a' * 500;
    await gw.send(OutboundMessage(
      sessionKey: 'x:100',
      text: longText,
    ));
    expect(sendBodies.length, 1);
    final body = jsonDecode(sendBodies.single['body'] as String)
        as Map<String, dynamic>;
    expect(body['text'].toString().length, 280);
    expect((body['reply'] as Map)['in_reply_to_tweet_id'], '100');
  });

  test('X-3: allowlist kosong — semua mention didrop (fail-closed)', () async {
    mentionsPayload = {
      'data': [
        {
          'id': '200',
          'text': '@bot halo',
          'author_id': '42',
          'conversation_id': '200',
        },
      ],
    };
    final gw = gateway(allow: {});
    final received = <InboundMessage>[];
    final sub = gw.inbound.listen(received.add);
    await gw.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await gw.stop();
    await sub.cancel();
    expect(received, isEmpty);
  });

  test('X-4: API error tidak menghentikan loop; loop berhenti di stop()',
      () async {
    mentionsPayload = {'errors': [{'code': 403}]};
    final gw = gateway(allow: {'42'});
    await gw.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(gw.running, isTrue, reason: 'error polling tidak membunuh loop');
    mentionsPayload = {
      'data': [
        {
          'id': '300',
          'text': '@bot setelah error',
          'author_id': '42',
          'conversation_id': '300',
        },
      ],
    };
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await gw.stop();
    expect(gw.running, isFalse);
    await gw.close();
  });

  test('X-5: komparasi snowflake id — panjang beda, numerik lebih besar',
      () async {
    mentionsPayload = {
      'data': [
        {
          'id': '999',
          'text': '@bot lama',
          'author_id': '42',
          'conversation_id': '999',
        },
        {
          'id': '10000',
          'text': '@bot baru (id numerik lebih besar)',
          'author_id': '42',
          'conversation_id': '10000',
        },
      ],
    };
    final gw = gateway(allow: {'42'});
    final received = <InboundMessage>[];
    final sub = gw.inbound.listen(received.add);
    await gw.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await gw.stop();
    await sub.cancel();
    // Poll berikutnya seharusnya memakai since_id=10000 (id terbesar numerik,
    // bukan '999' yang lexically lebih besar).
    expect(received.length, 2);
    expect(received.last.meta['tweet_id'], '10000');
  });
}
