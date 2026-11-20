import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Hermes Relay gateway for connecting to Hermes Agent AI relay service.
///
/// Hermes Relay is a message relay service that allows agents to communicate
/// with each other and with external services via a centralized relay.
///
/// Configuration:
/// - relayUrl: Hermes Relay server URL (default: https://relay.nousresearch.com)
/// - agentId: Unique identifier for this agent
/// - accessToken: Authentication token for the relay service
///
/// Reference: https://github.com/NousResearch/hermes-relay
class HermesRelayGateway implements Gateway {
  HermesRelayGateway({
    required this.agentId,
    required this.accessToken,
    this.relayUrl = 'https://relay.nousresearch.com',
    this.httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _relayUrl = relayUrl.endsWith('/')
            ? relayUrl.substring(0, relayUrl.length - 1)
            : relayUrl;

  final String agentId;
  final String accessToken;
  final String _relayUrl;
  final String relayUrl;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();
  bool _running = false;
  Timer? _pollTimer;

  @override
  String get channel => 'hermes_relay';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (from relay webhook or polling).
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

  /// Start polling for messages from the relay.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_pollLoop());
  }

  /// Stop polling.
  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        await _pollMessages();
        await Future.delayed(const Duration(seconds: 5));
      } catch (e) {
        // Log error but continue polling
        await Future.delayed(const Duration(seconds: 10));
      }
    }
  }

  Future<void> _pollMessages() async {
    final client = httpClient ?? http.Client();
    try {
      final url = Uri.parse('$_relayUrl/api/v1/messages?agent_id=$agentId');
      final response = await client
          .get(
            url,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final messages = json['messages'] as List<dynamic>? ?? [];
        for (final msg in messages) {
          final msgMap = msg as Map<String, dynamic>;
          pushInbound(
            userKey: msgMap['user_id'] as String? ?? 'unknown',
            sessionKey: msgMap['session_id'] as String? ?? 'default',
            text: msgMap['content'] as String? ?? '',
            meta: {
              'message_id': msgMap['id'],
              'timestamp': msgMap['timestamp'],
              'source': 'hermes_relay',
            },
          );
        }
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final target = m.meta['target'] as String? ?? 'default';
      final sessionKey = m.meta['session_key'] as String? ?? m.sessionKey;

      final payload = {
        'agent_id': agentId,
        'target': target,
        'session_id': sessionKey,
        'content': m.text,
        'meta': m.meta,
      };

      final url = Uri.parse('$_relayUrl/api/v1/messages');
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
          'Hermes Relay API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a message to a specific agent via relay.
  Future<void> sendToAgent({
    required String targetAgentId,
    required String content,
    String? sessionId,
    Map<String, dynamic>? meta,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final payload = {
        'agent_id': agentId,
        'target_agent_id': targetAgentId,
        'content': content,
        if (sessionId != null) 'session_id': sessionId,
        if (meta != null) 'meta': meta,
      };

      final url = Uri.parse('$_relayUrl/api/v1/messages/agent');
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
          'Hermes Relay agent message error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Broadcast a message to all connected agents.
  Future<void> broadcast(String content, {Map<String, dynamic>? meta}) async {
    final client = httpClient ?? http.Client();
    try {
      final payload = {
        'agent_id': agentId,
        'content': content,
        if (meta != null) 'meta': meta,
      };

      final url = Uri.parse('$_relayUrl/api/v1/messages/broadcast');
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
          'Hermes Relay broadcast error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Hermes Relay doesn't support typing indicators
  }

  @override
  Future<void> close() async {
    await stop();
    await _inbound.close();
  }
}
