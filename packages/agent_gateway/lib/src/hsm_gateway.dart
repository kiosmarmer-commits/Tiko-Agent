import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// HSM (Hermes desktop) gateway for connecting to Hermes desktop application.
///
/// HSM (Hermes State Manager) is the desktop component of Hermes Agent AI
/// that provides a local interface for agent communication.
///
/// Configuration:
/// - hsmUrl: HSM server URL (default: http://localhost:8080)
/// - agentId: Unique identifier for this agent
/// - accessToken: Authentication token for HSM
///
/// Reference: https://github.com/NousResearch/hermes
class HsmGateway implements Gateway {
  HsmGateway({
    required this.agentId,
    this.accessToken,
    this.hsmUrl = 'http://localhost:8080',
    this.httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _hsmUrl = hsmUrl.endsWith('/')
            ? hsmUrl.substring(0, hsmUrl.length - 1)
            : hsmUrl;

  final String agentId;
  final String? accessToken;
  final String _hsmUrl;
  final String hsmUrl;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();
  bool _running = false;
  Timer? _pollTimer;

  @override
  String get channel => 'hsm';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (from HSM webhook or polling).
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

  /// Start polling for messages from HSM.
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
        await Future.delayed(const Duration(seconds: 3));
      } catch (e) {
        // Log error but continue polling
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<void> _pollMessages() async {
    final client = httpClient ?? http.Client();
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final url = Uri.parse('$_hsmUrl/api/v1/agents/$agentId/messages');
      final response = await client
          .get(
            url,
            headers: headers,
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
              'source': 'hsm',
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

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final payload = {
        'agent_id': agentId,
        'target': target,
        'session_id': sessionKey,
        'content': m.text,
        'meta': m.meta,
      };

      final url = Uri.parse('$_hsmUrl/api/v1/agents/$agentId/messages');
      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'HSM API error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a message to a specific agent via HSM.
  Future<void> sendToAgent({
    required String targetAgentId,
    required String content,
    String? sessionId,
    Map<String, dynamic>? meta,
  }) async {
    final client = httpClient ?? http.Client();
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final payload = {
        'from_agent_id': agentId,
        'to_agent_id': targetAgentId,
        'content': content,
        if (sessionId != null) 'session_id': sessionId,
        if (meta != null) 'meta': meta,
      };

      final url = Uri.parse('$_hsmUrl/api/v1/agents/$agentId/messages/to/$targetAgentId');
      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'HSM agent message error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Register this agent with HSM.
  Future<void> register() async {
    final client = httpClient ?? http.Client();
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final payload = {
        'agent_id': agentId,
        'name': agentId,
        'capabilities': {'chat': true, 'tools': true},
      };

      final url = Uri.parse('$_hsmUrl/api/v1/agents/register');
      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'HSM registration error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Unregister this agent from HSM.
  Future<void> unregister() async {
    final client = httpClient ?? http.Client();
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (accessToken != null && accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final url = Uri.parse('$_hsmUrl/api/v1/agents/$agentId/unregister');
      final response = await client
          .post(
            url,
            headers: headers,
          )
          .timeout(timeout);

      if (response.statusCode >= 400) {
        throw StateError(
          'HSM unregistration error: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // HSM doesn't support typing indicators by default
  }

  @override
  Future<void> close() async {
    await stop();
    await _inbound.close();
  }
}
