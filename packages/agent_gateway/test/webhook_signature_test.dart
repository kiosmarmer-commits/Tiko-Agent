import 'dart:convert';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

String hmac(String secret, String data) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(data)).toString();

void main() {
  test('verifyMeta accepts a correct WhatsApp signature', () {
    const body = '{"object":"whatsapp_business_account"}';
    const secret = 'app-secret';
    final sig = 'sha256=${hmac(secret, body)}';
    expect(
      WebhookSignature.verifyMeta(
        rawBody: body,
        headerValue: sig,
        appSecret: secret,
      ),
      isTrue,
    );
  });

  test('verifyMeta rejects tampering and wrong secrets', () {
    const body = '{"a":1}';
    const secret = 's';
    final sig = 'sha256=${hmac(secret, body)}';
    expect(
      WebhookSignature.verifyMeta(
        rawBody: '{"a":2}',
        headerValue: sig,
        appSecret: secret,
      ),
      isFalse,
    );
    expect(
      WebhookSignature.verifyMeta(
        rawBody: body,
        headerValue: sig,
        appSecret: 'other',
      ),
      isFalse,
    );
    expect(
      WebhookSignature.verifyMeta(
        rawBody: body,
        headerValue: 'sha256=deadbeef',
        appSecret: secret,
      ),
      isFalse,
    );
  });

  test('verifySlack accepts a fresh signed request', () {
    const body = '{"type":"event_callback"}';
    const secret = 'signing-secret';
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;
    final sig = 'v0=${hmac(secret, 'v0:$ts:$body')}';
    expect(
      WebhookSignature.verifySlack(
        rawBody: body,
        timestampSeconds: '$ts',
        headerValue: sig,
        signingSecret: secret,
      ),
      isTrue,
    );
  });

  test('verifySlack rejects stale and badly signed requests', () {
    const body = '{"type":"event_callback"}';
    const secret = 'signing-secret';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final oldTs = now - 600;
    final oldSig = 'v0=${hmac(secret, 'v0:$oldTs:$body')}';
    expect(
      WebhookSignature.verifySlack(
        rawBody: body,
        timestampSeconds: '$oldTs',
        headerValue: oldSig,
        signingSecret: secret,
      ),
      isFalse,
    );
    final badSig = 'v0=${'0' * 64}';
    expect(
      WebhookSignature.verifySlack(
        rawBody: body,
        timestampSeconds: '$now',
        headerValue: badSig,
        signingSecret: secret,
      ),
      isFalse,
    );
  });
}
