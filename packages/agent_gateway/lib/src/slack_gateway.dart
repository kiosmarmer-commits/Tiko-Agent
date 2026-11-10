import 'dart:convert';

import 'package:http/http.dart' as http;

/// FR-07 (Multi-Platform Gateway): Slack integration.
///
/// - [SlackGateway.send] posts messages via an Incoming Webhook URL
///   (simplest, no OAuth dance) or a bot token + channel combination.
/// - [SlackGateway.verifyEvent] checks the (deprecated but still common)
///   single-team `token` field of the Events API payload.
/// - [SlackGateway.parseEventCommand] extracts slash-command style input.
class SlackGateway {
  SlackGateway({
    this.webhookUrl,
    this.botToken,
    this.verifyToken,
    this.client,
  }) : assert(
          (webhookUrl != null && webhookUrl.isNotEmpty) ||
              (botToken != null && botToken.isNotEmpty),
          'webhookUrl atau botToken wajib diisi',
        );

  /// Incoming Webhook: https://hooks.slack.com/services/...
  final String? webhookUrl;

  /// xoxb-... bot token for chat.postMessage.
  final String? botToken;

  /// Shared verify token from the Slack app config (Events API).
  final String? verifyToken;

  final http.Client? client;

  http.Client get _client => client ?? http.Client();

  /// Sends a text message. Uses the bot token + chat.postMessage when
  /// configured, otherwise the incoming webhook.
  Future<bool> send(String text, {String? channel}) async {
    if (text.trim().isEmpty) throw ArgumentError('text kosong');
    if (text.length > 4000) {
      throw ArgumentError('text terlalu panjang (maks 4000 karakter)');
    }
    if (botToken != null && botToken!.isNotEmpty && channel != null) {
      final resp = await _client.post(
        Uri.parse('https://slack.com/api/chat.postMessage'),
        headers: {
          'Authorization': 'Bearer $botToken',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({'channel': channel, 'text': text}),
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      final map = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      return map is Map && map['ok'] == true;
    }
    final hook = webhookUrl;
    if (hook == null || hook.isEmpty) {
      throw StateError('channel wajib saat memakai bot token');
    }
    final resp = await _client.post(
      Uri.parse(hook),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({'text': text}),
    ).timeout(const Duration(seconds: 30));
    return resp.statusCode == 200;
  }

  /// URL-encoded slash-command payload (application/x-www-form-urlencoded)
  /// → {command, text, userId, channelId}.
  Map<String, String> parseSlashCommand(Map<String, String> form) {
    return {
      'command': form['command'] ?? '',
      'text': form['text'] ?? '',
      'userId': form['user_id'] ?? '',
      'channelId': form['channel_id'] ?? '',
    };
  }

  /// Events API payload verification. Returns true when the payload's
  /// token matches [verifyToken]. Note: modern Slack apps should use the
  /// signed `X-Slack-Signature` header; that requires `package:crypto`
  /// (same caveat as the WhatsApp gateway).
  bool verifyEvent(Map<String, dynamic> payload) {
    final expected = verifyToken;
    if (expected == null || expected.isEmpty) return false;
    return payload['token'] == expected;
  }

  /// Extracts user text from an Events API `message` event.
  /// Returns null for non-message or bot-authored events (avoid loops).
  Map<String, String>? parseEventMessage(Map<String, dynamic> payload) {
    final event = payload['event'];
    if (event is! Map) return null;
    if (event['type'] != 'message') return null;
    if (event['subtype'] != null) return null;
    // Never reply to bot messages: that creates infinite loops.
    if (event['bot_id'] != null || event['bot_profile'] != null) return null;
    final text = event['text']?.toString() ?? '';
    if (text.isEmpty) return null;
    return {
      'text': text,
      'userId': event['user']?.toString() ?? '',
      'channelId': event['channel']?.toString() ?? '',
      'ts': event['ts']?.toString() ?? '',
    };
  }
}
