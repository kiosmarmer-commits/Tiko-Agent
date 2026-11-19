import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Microsoft Teams webhook gateway.
///
/// Teams supports incoming webhooks for posting messages to channels.
/// This gateway sends messages via outgoing webhooks.
/// For receiving messages, Teams uses Bot Framework which requires
/// more complex setup (not implemented in this basic version).
///
/// Configuration:
/// - Create an incoming webhook connector in your Teams channel
/// - Get the webhook URL (format: https://outlook.office.com/webhook/...)
/// - Set as `webhookUrl` in constructor
///
/// Reference: https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook
class TeamsGateway implements Gateway {
  TeamsGateway({
    required this.webhookUrl,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String webhookUrl;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'teams';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (for testing or webhook reception).
  /// Teams typically receives messages via Bot Framework, not webhooks.
  /// This method can be used if you have a separate webhook receiver.
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
      // Extract optional metadata
      final channelId = m.meta['channel_id'] as String?;
      final threadId = m.meta['thread_id'] as String?;

      final payload = {
        '@type': 'MessageCard',
        '@context': 'https://schema.org/extensions',
        'summary': m.text.length > 100 ? m.text.substring(0, 100) : m.text,
        'sections': [
          {
            'text': m.text,
            'markdown': m.markdown,
          },
        ],
        if (channelId != null) 'channelId': channelId,
        if (threadId != null) 'threadId': threadId,
      };

      final response = await client
          .post(
            Uri.parse(webhookUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Teams webhook error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Teams doesn't have a direct typing indicator API via webhooks.
    // This is a no-op for the basic webhook implementation.
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
