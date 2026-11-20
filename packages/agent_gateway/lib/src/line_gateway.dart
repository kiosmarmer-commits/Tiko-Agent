import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// LINE Messaging API gateway.
///
/// Requires a LINE Messaging API channel:
/// 1. Create a LINE Developers account: https://developers.line.biz/
/// 2. Create a Messaging API channel
/// 3. Get the Channel Access Token and Channel Secret
///
/// Reference: https://developers.line.biz/en/docs/messaging-api/
///
class LineGateway implements Gateway {
  LineGateway({
    required this.channelAccessToken,
    required this.channelSecret,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String channelAccessToken;
  final String channelSecret;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'line';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Verify LINE webhook signature.
  /// LINE sends a signature in the X-Line-Signature header.
  /// The signature is HMAC-SHA256 over the raw request body, encoded as base64.
  ///
  /// Comparison is performed byte-by-byte without early exit so that malformed
  /// signatures do not become a timing oracle.
  static bool verifySignature(
    String channelSecret,
    String body,
    String signature,
  ) {
    if (channelSecret.isEmpty || body.isEmpty || signature.isEmpty) {
      return false;
    }
    final digest = Hmac(
      sha256,
      utf8.encode(channelSecret),
    ).convert(utf8.encode(body));
    final expected = base64.encode(digest.bytes);
    if (expected.length != signature.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ signature.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// Push an inbound message from LINE webhook.
  void pushInbound({required Map<String, dynamic> webhookData}) {
    try {
      final events = webhookData['events'] as List<dynamic>? ?? [];
      for (final event in events) {
        final eventMap = event as Map<String, dynamic>;
        final type = eventMap['type'] as String? ?? '';

        if (type == 'message') {
          final message = eventMap['message'] as Map<String, dynamic>? ?? {};
          final text = message['text'] as String? ?? '';
          final source = eventMap['source'] as Map<String, dynamic>? ?? {};
          final userId = source['userId'] as String? ?? '';
          final groupId = source['groupId'] as String?;
          final roomId = source['roomId'] as String?;

          final sessionKey = groupId != null
              ? 'line:group:$groupId'
              : (roomId != null ? 'line:room:$roomId' : 'line:user:$userId');

          _inbound.add(
            InboundMessage(
              channel: channel,
              userKey: userId,
              sessionKey: sessionKey,
              text: text,
              meta: {'source': source, 'message': message, 'event': eventMap},
            ),
          );
        }
      }
    } catch (e) {
      // Silently ignore malformed webhook data
    }
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final replyToken = m.meta['reply_token'] as String?;
      final to = m.meta['to'] as String?;

      if (replyToken == null && to == null) {
        throw StateError(
          'LINE: reply_token or to (userId/groupId/roomId) required',
        );
      }

      final payload = {
        if (replyToken != null) 'replyToken': replyToken,
        if (to != null) 'to': to,
        'messages': [
          {'type': 'text', 'text': m.text},
        ],
      };

      final response = await client
          .post(
            Uri.parse('https://api.line.me/v2/bot/message/push'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $channelAccessToken',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'LINE API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // LINE doesn't have a direct typing indicator API
    // This is a no-op
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
