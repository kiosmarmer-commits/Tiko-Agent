import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Mattermost REST API gateway.
///
/// Mattermost is an open-source, self-hostable Slack alternative.
/// This gateway uses the Mattermost REST API v4.
///
/// Configuration:
/// - serverUrl: Your Mattermost server URL (e.g., https://mattermost.example.com)
/// - token: Bot token or user token
/// - defaultChannel: Default channel for messages without explicit channel
///
/// Reference: https://api.mattermost.com/v4
class MattermostGateway implements Gateway {
  MattermostGateway({
    required this.serverUrl,
    required this.token,
    this.defaultChannel,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String serverUrl;
  final String token;
  final String? defaultChannel;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'mattermost';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message from Mattermost webhook.
  void pushInbound({
    required Map<String, dynamic> webhookData,
  }) {
    try {
      final userId = webhookData['user_id'] as String? ?? '';
      final channelId = webhookData['channel_id'] as String? ?? '';
      final text = webhookData['text'] as String? ?? '';
      final postId = webhookData['post_id'] as String?;
      final teamId = webhookData['team_id'] as String?;

      _inbound.add(
        InboundMessage(
          channel: channel,
          userKey: userId,
          sessionKey: 'mattermost:$channelId',
          text: text,
          meta: {
            'user_id': userId,
            'channel_id': channelId,
            'post_id': postId,
            'team_id': teamId,
          },
        ),
      );
    } catch (e) {
      // Silently ignore malformed webhook data
    }
  }

  Uri _api(String path) => Uri.parse('$serverUrl/api/v4$path');

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final channelId = m.meta['channel_id'] as String? ?? defaultChannel;
      if (channelId == null || channelId.isEmpty) {
        throw StateError('Mattermost: channel_id or defaultChannel required');
      }

      final payload = {
        'channel_id': channelId,
        'message': m.text,
      };

      final response = await client
          .post(
            _api('/posts'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Mattermost API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Mattermost doesn't have a direct typing indicator API
    // This is a no-op
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
