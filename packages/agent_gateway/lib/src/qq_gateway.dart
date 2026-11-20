import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// QQ Bot gateway for sending messages to QQ groups or users.
///
/// This gateway supports sending messages via QQ Bot API.
/// Note: This uses the OpenQQ API or similar third-party APIs.
///
/// Configuration:
/// - botToken: QQ Bot token
/// - groupId: Target QQ group ID (optional, can be specified per message)
///
/// Reference: https://bot.q.qq.com/wiki/
class QqGateway implements Gateway {
  QqGateway({
    required this.botToken,
    this.defaultGroupId,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String botToken;
  final String? defaultGroupId;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'qq';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (QQ Bot can receive messages via webhooks).
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
      // Extract group ID from metadata or use default
      final groupId = m.meta['group_id'] as String? ?? defaultGroupId;
      if (groupId == null || groupId.isEmpty) {
        throw StateError('QQ Bot requires group_id in message metadata or defaultGroupId');
      }

      // Build the message payload
      final payload = {
        'group_id': groupId,
        'message': m.text,
        'auto_escape': true, // Auto escape special characters
      };

      final url = Uri.parse('https://api.sgroup.qq.com/api/v2/group_send_msg');

      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $botToken',
      };

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['retcode'] != 0) {
        throw StateError(
          'QQ Bot API error: ${responseData['message']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a message to a specific QQ user (private message).
  Future<void> sendPrivateMessage(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      // Extract user ID from metadata
      final userId = m.meta['user_id'] as String?;
      if (userId == null || userId.isEmpty) {
        throw StateError('QQ private message requires user_id in message metadata');
      }

      // Build the private message payload
      final payload = {
        'user_id': userId,
        'message': m.text,
        'auto_escape': true,
      };

      final url = Uri.parse('https://api.sgroup.qq.com/api/v2/private_send_msg');

      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $botToken',
      };

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['retcode'] != 0) {
        throw StateError(
          'QQ Bot API error: ${responseData['message']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a rich message with images or other media.
  Future<void> sendRichMessage(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final groupId = m.meta['group_id'] as String? ?? defaultGroupId;
      if (groupId == null || groupId.isEmpty) {
        throw StateError('QQ Bot requires group_id in message metadata or defaultGroupId');
      }

      // Extract image URL from metadata
      final imageUrl = m.meta['image_url'] as String?;

      if (imageUrl != null && imageUrl.isNotEmpty) {
        // Send image message
        final payload = {
          'group_id': groupId,
          'message': [
            {
              'type': 'image',
              'data': {
                'file': imageUrl,
              },
            },
            {
              'type': 'text',
              'data': {
                'text': m.text,
              },
            },
          ],
          'auto_escape': true,
        };

        final url = Uri.parse('https://api.sgroup.qq.com/api/v2/group_send_msg');

        final headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $botToken',
        };

        final response = await client
            .post(
              url,
              headers: headers,
              body: jsonEncode(payload),
            )
            .timeout(timeout);

        final responseData = jsonDecode(response.body) as Map<String, dynamic>;

        if (responseData['retcode'] != 0) {
          throw StateError(
            'QQ Bot API error: ${responseData['message']}',
          );
        }
      } else {
        // Fall back to text message
        await send(m);
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // QQ Bot doesn't support typing indicators
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
