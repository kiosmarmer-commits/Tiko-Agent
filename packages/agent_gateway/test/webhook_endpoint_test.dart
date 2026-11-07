import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

String metaSig(String secret, String body) => 'sha256=' +
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body)).toString();

String slackSig(String secret, String ts, String body) => 'v0=' +
    Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode('v0:$ts:$body'))
        .toString();

void main() {
  late HttpApiServer server;
  late List<InboundMessage> received;

  setUp(() async {
    received = [];
    server = HttpApiServer(
      onMessage: (m) async => 'ok',
      authToken: 'test-token-for-webhooks',
      host: '127.0.0.1',
      port: 0,
      webhookEndpoint: WebhookEndpoint(
        whatsapp: WhatsAppGateway(
          phoneNumberId: '123',
          accessToken: 'token',
          verifyToken: 'verify-me',
        ),
        whatsappAppSecret: 'wa-secret',
        slack: SlackGateway(webhookUrl: 'https://hooks.slack.com/x'),
        slackSigningSecret: 'slack-secret',
        onMessage: (m) async => received.add(m),
      ),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Uri uri(String path) =>
      Uri.parse('http://127.0.0.1:${server.boundPort}$path');

  Future<(int, String)> post(
    String path,
    String body,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri(path));
      for (final h in headers.entries) {
        req.headers.set(h.key, h.value);
      }
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  test('whatsapp handshake echoes the challenge', () async {
    final client = HttpClient();
    try {
      final res = await client.getUrl(uri(
        '/webhooks/whatsapp'
        '?hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=abc123',
      ));
      final r = await res.close();
      final text = await r.transform(utf8.decoder).join();
      expect(r.statusCode, 200);
      expect(text, 'abc123');
    } finally {
      client.close(force: true);
    }
  });

  test('whatsapp message with a valid signature is dispatched', () async {
    final msg = {'type': 'text', 'from': '628123456789', 'text': {'body': 'halo'}};
    final body = jsonEncode({
      'entry': [
        {
          'changes': [
            {'value': {'messages': [msg]}},
          ],
        },
      ],
    });
    final (status, text) = await post('/webhooks/whatsapp', body, {
      'X-Hub-Signature-256': metaSig('wa-secret', body),
    });
    expect(status, 200);
    expect((jsonDecode(text) as Map)['accepted'], 1);
    expect(received, hasLength(1));
    expect(received.single.channel, 'whatsapp');
    expect(received.single.text, 'halo');
    expect(received.single.sessionKey, 'wa:628123456789');
  });

  test('whatsapp message without a valid signature is rejected', () async {
    const body = '{"entry":[]}';
    final (status, _) = await post('/webhooks/whatsapp', body, {
      'X-Hub-Signature-256': 'sha256=deadbeef',
    });
    expect(status, 401);
    expect(received, isEmpty);
  });

  test('slack url_verification echoes the challenge', () async {
    final body = jsonEncode({
      'type': 'url_verification',
      'challenge': 'ping-42',
    });
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (status, text) = await post('/webhooks/slack', body, {
      'X-Slack-Signature': slackSig('slack-secret', '$ts', body),
      'X-Slack-Request-Timestamp': '$ts',
    });
    expect(status, 200);
    expect((jsonDecode(text) as Map)['challenge'], 'ping-42');
  });

  test('slack event_callback dispatches the message', () async {
    final event = {
      'type': 'message',
      'user': 'U1',
      'channel': 'C1',
      'text': 'halo slack',
      'ts': '1',
    };
    final body = jsonEncode({'type': 'event_callback', 'event': event});
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (status, _) = await post('/webhooks/slack', body, {
      'X-Slack-Signature': slackSig('slack-secret', '$ts', body),
      'X-Slack-Request-Timestamp': '$ts',
    });
    expect(status, 200);
    expect(received, hasLength(1));
    expect(received.single.channel, 'slack');
    expect(received.single.text, 'halo slack');
    expect(received.single.sessionKey, 'slack:C1');
  });

  test('webhook routes are disabled without configuration', () async {
    final bare = HttpApiServer(
      onMessage: (m) async => 'ok',
      authToken: 't',
      host: '127.0.0.1',
      port: 0,
    );
    await bare.start();
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bare.boundPort}/webhooks/whatsapp'),
      );
      req.write('{}');
      final res = await req.close();
      expect(res.statusCode, 403);
    } finally {
      client.close(force: true);
      await bare.stop();
    }
  });
}
