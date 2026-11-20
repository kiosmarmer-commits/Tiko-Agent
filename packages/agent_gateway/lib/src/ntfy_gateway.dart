import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// ntfy gateway for sending notifications via ntfy.sh.
///
/// ntfy (notify) is a simple HTTP-based pub/sub notification service.
/// This gateway sends messages to ntfy topics.
///
/// Configuration:
/// - topic: The ntfy topic to publish to (e.g., "my_topic")
/// - baseUrl: ntfy server URL (default: https://ntfy.sh)
/// - accessToken: Optional access token for authenticated topics
///
/// Reference: https://ntfy.sh/docs/publish/
class NtfyGateway implements Gateway {
  NtfyGateway({
    required this.topic,
    this.baseUrl = 'https://ntfy.sh',
    this.accessToken,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
    this.priority = 3, // default priority
    this.tags = const [],
  });

  final String topic;
  final String baseUrl;
  final String? accessToken;
  final http.Client? httpClient;
  final Duration timeout;
  final int priority; // 1-5, where 1=min, 3=default, 5=max
  final List<String> tags;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'ntfy';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (ntfy is primarily outbound, but can receive via webhooks).
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
      // Build headers
      final headers = <String, String>{
        'Content-Type': 'text/plain',
        'Title': m.meta['title'] as String? ?? 'Tiko-Agent Notification',
        'Priority': priority.toString(),
      };

      // Add tags if present
      if (tags.isNotEmpty) {
        headers['Tags'] = tags.join(',');
      }

      // Add authentication if token is provided
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      // Build the message body
      // ntfy supports plain text or JSON
      final body = m.markdown ? _markdownToPlain(m.text) : m.text;

      // Build URL with topic
      final url = Uri.parse('$baseUrl/$topic');

      final response = await client
          .post(
            url,
            headers: headers,
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'ntfy error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // ntfy doesn't support typing indicators
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }

  /// Simple markdown to plain text conversion for ntfy
  String _markdownToPlain(String markdown) {
    return markdown
        .replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'\1') // **bold**
        .replaceAll(RegExp(r'\*([^*]+)\*'), r'\1') // *italic*
        .replaceAll(RegExp(r'`([^`]+)`'), r'\1') // `code`
        .replaceAll(RegExp(r'\n\n+'), '\n\n') // Multiple newlines
        .replaceAll(RegExp(r'^\[.*\]\s*'), '') // Remove markdown links
        .replaceAll(RegExp(r'!\['), '') // Remove image syntax
        .replaceAll(RegExp(r'\]\(.*\)'), '');
  }
}
