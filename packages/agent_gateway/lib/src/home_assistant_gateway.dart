import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Home Assistant gateway for sending notifications and receiving events.
///
/// This gateway integrates with Home Assistant's REST API for sending
/// notifications and can receive events via webhooks.
///
/// Configuration:
/// - baseUrl: Home Assistant base URL (e.g., http://localhost:8123)
/// - accessToken: Long-lived access token from Home Assistant
/// - notifyService: The notification service to use (default: notify.notify)
///
/// Reference: https://developers.home-assistant.io/docs/api/rest/
class HomeAssistantGateway implements Gateway {
  HomeAssistantGateway({
    required this.baseUrl,
    required this.accessToken,
    this.notifyService = 'notify.notify',
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl.endsWith('/') 
            ? baseUrl.substring(0, baseUrl.length - 1) 
            : baseUrl;

  final String _baseUrl;
  final String baseUrl;
  final String accessToken;
  final String notifyService;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'home_assistant';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (from Home Assistant webhook).
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
      final target = m.meta['target'] as String? ?? 'default';
      final title = m.meta['title'] as String? ?? 'Tiko-Agent';
      final data = m.meta['data'] as Map<String, dynamic>? ?? {};

      // Build the service call payload
      final payload = {
        'service': notifyService,
        'data': {
          'message': m.text,
          'title': title,
          'target': target,
          ...data,
        },
      };

      // Remove null values
      payload['data'].removeWhere((key, value) => value == null);

      final url = Uri.parse('$_baseUrl/api/services/notify/send');

      final response = await client
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Home Assistant API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Call any Home Assistant service.
  ///
  /// This is a generic method to call any service in Home Assistant.
  /// Example: Call light.turn_on service
  /// ```dart
  /// await callService(
  ///   domain: 'light',
  ///   service: 'turn_on',
  ///   data: {'entity_id': 'light.living_room'},
  /// );
  /// ```
  Future<void> callService({
    required String domain,
    required String service,
    Map<String, dynamic>? data,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final payload = {
        'service': '$domain.$service',
        if (data != null) 'data': data,
      };

      final url = Uri.parse('$_baseUrl/api/services/$domain/$service');

      final response = await client
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Home Assistant API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Get the state of a Home Assistant entity.
  Future<Map<String, dynamic>> getEntityState(String entityId) async {
    final client = httpClient ?? http.Client();
    try {
      final url = Uri.parse('$_baseUrl/api/states/$entityId');

      final response = await client
          .get(
            url,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'Home Assistant API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Home Assistant doesn't support typing indicators
  }

  @override
  Future<void> sendStreamChunk(String sessionKey, String chunk) async {
    // Home Assistant doesn't support streaming
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
