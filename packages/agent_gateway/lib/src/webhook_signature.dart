import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC-SHA256 verification for inbound webhooks (WhatsApp Cloud API and
/// Slack Events API). Comparisons are constant-time to avoid leaking
/// signature bytes through timing.
abstract final class WebhookSignature {
  /// Meta (WhatsApp Cloud API): `X-Hub-Signature-256: sha256=<hex>` over
  /// the raw request body, keyed with the app secret.
  static bool verifyMeta({
    required String rawBody,
    required String headerValue,
    required String appSecret,
  }) {
    final digest = Hmac(sha256, utf8.encode(appSecret))
        .convert(utf8.encode(rawBody))
        .toString();
    return _constantTimeEquals('sha256=$digest', headerValue.trim());
  }

  /// Slack Events API: `X-Slack-Signature: v0=<hex>` over
  /// `v0:<timestamp>:<body>` keyed with the signing secret, with a
  /// bounded replay window on the request timestamp.
  static bool verifySlack({
    required String rawBody,
    required String timestampSeconds,
    required String headerValue,
    required String signingSecret,
    Duration maxAge = const Duration(minutes: 5),
    int? nowSeconds,
  }) {
    final ts = int.tryParse(timestampSeconds);
    if (ts == null) return false;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((now - ts).abs() > maxAge.inSeconds) return false;
    final base = 'v0:$timestampSeconds:$rawBody';
    final digest = Hmac(sha256, utf8.encode(signingSecret))
        .convert(utf8.encode(base))
        .toString();
    return _constantTimeEquals('v0=$digest', headerValue.trim());
  }

  static bool _constantTimeEquals(String expected, String actual) {
    final left = utf8.encode(expected);
    final right = utf8.encode(actual);
    // Compare over the longer input and pad the shorter with zeros so
    // neither the loop count nor an early return leaks the mismatch.
    var diff = left.length ^ right.length;
    final longest = left.length >= right.length ? left : right;
    final shortest = left.length >= right.length ? right : left;
    for (var i = 0; i < longest.length; i++) {
      final other = i < shortest.length ? shortest[i] : 0;
      diff |= longest[i] ^ other;
    }
    return diff == 0;
  }
}
