import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Yuanbao (元宝) gateway for sending messages.
///
/// Yuanbao is a Chinese notification service.
/// This gateway supports sending messages via webhooks.
///
/// Configuration:
/// - webhookUrl: Yuanbao webhook URL
/// - token: Optional authentication token
///
/// Note: Yuanbao API documentation is limited. This implementation
/// assumes a REST API similar to other Chinese notification services.
class YuanbaoGateway implements Gateway {
  YuanbaoGateway({
    required this.webhookUrl,
    this.token,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String webhookUrl;
  final String? token;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'yuanbao';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (Yuanbao is primarily outbound via webhooks).
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
        'Content-Type': 'application/json',
      };

      // Add authentication if token is provided
      if (token != null && token!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      // Build the message payload
      // Assuming Yuanbao uses a simple JSON format
      final payload = {
        'title': m.meta['title'] as String? ?? 'Tiko-Agent Notification',
        'content': m.text,
        'type': 'text',
        // Add optional fields from metadata
        if (m.meta['priority'] != null) 'priority': m.meta['priority'],
        if (m.meta['tags'] != null) 'tags': m.meta['tags'],
      };

      final url = Uri.parse(webhookUrl);

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Yuanbao API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a markdown message to Yuanbao.
  Future<void> sendMarkdown(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      // Build headers
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      // Add authentication if token is provided
      if (token != null && token!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      // Build the markdown payload
      final payload = {
        'title': m.meta['title'] as String? ?? 'Tiko-Agent Notification',
        'content': m.text,
        'type': 'markdown',
      };

      final url = Uri.parse(webhookUrl);

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Yuanbao API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Yuanbao doesn't support typing indicators
  }

  @override
  Future<void> sendStreamChunk(String sessionKey, String chunk) async {
    // Yuanbao doesn't support streaming
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
