import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Feishu (飞书) / Lark gateway for sending messages.
///
/// Feishu (Lark) is a Chinese enterprise collaboration platform.
/// This gateway supports sending messages via webhooks.
///
/// Configuration:
/// - webhookUrl: Feishu webhook URL (from bot settings)
/// - secret: Optional secret for signature verification
///
/// Reference: https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/im/im-v1/message/create
class FeishuGateway implements Gateway {
  FeishuGateway({
    required this.webhookUrl,
    this.secret,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String webhookUrl;
  final String? secret;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'feishu';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (Feishu is primarily outbound via webhooks).
  void pushInbound({
    required String userKey,
    required String sessionKey,
    required String text,
    Map<String, Object?> meta = const {},
  }) {
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: userKey,
        sessionKey: sessionKey,
        text: text,
        meta: meta,
      ),
    );
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      // Build the message payload
      final payload = {
        'msg_type': 'text',
        'content': {
          'text': m.text,
        },
      };

      final url = Uri.parse(webhookUrl);

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400 || responseData['StatusCode'] != 0) {
        final errorMsg = responseData['StatusMessage'] as String? ?? response.body;
        throw StateError(
          'Feishu API error: HTTP ${response.statusCode} - $errorMsg',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a rich text message with markdown to Feishu.
  Future<void> sendRichText(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      // Build rich text payload
      final elements = <Map<String, dynamic>>[];

      // Split by newlines and create text elements
      final lines = m.text.split('\n');
      for (final line in lines) {
        if (line.isEmpty) {
          elements.add({'tag': 'br'});
        } else {
          elements.add({
            'tag': 'text',
            'text': line,
          });
        }
      }

      final payload = {
        'msg_type': 'rich_text',
        'content': {
          'elements': elements,
        },
      };

      final url = Uri.parse(webhookUrl);

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400 || responseData['StatusCode'] != 0) {
        final errorMsg = responseData['StatusMessage'] as String? ?? response.body;
        throw StateError(
          'Feishu API error: HTTP ${response.statusCode} - $errorMsg',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a card message to Feishu.
  Future<void> sendCard(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final payload = {
        'msg_type': 'interactive',
        'card': {
          'config': {
            'wide_screen_mode': true,
          },
          'header': {
            'title': {
              'tag': 'plain_text',
              'content': m.meta['title'] as String? ?? 'Tiko-Agent Notification',
            },
          },
          'elements': [
            {
              'tag': 'div',
              'text': {
                'tag': 'lark_md',
                'content': m.text,
              },
            },
          ],
        },
      };

      final url = Uri.parse(webhookUrl);

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400 || responseData['StatusCode'] != 0) {
        final errorMsg = responseData['StatusMessage'] as String? ?? response.body;
        throw StateError(
          'Feishu API error: HTTP ${response.statusCode} - $errorMsg',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Feishu doesn't support typing indicators
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
