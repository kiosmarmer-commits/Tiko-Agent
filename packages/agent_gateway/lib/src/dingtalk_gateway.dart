import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

/// DingTalk (钉钉) gateway for sending messages to DingTalk groups or users.
///
/// DingTalk is a popular Chinese enterprise messaging and collaboration platform.
/// This gateway supports sending messages via webhooks.
///
/// Configuration:
/// - accessToken: DingTalk robot access token (from group robot settings)
/// - secret: Optional secret key for signature verification
///
/// Reference: https://open.dingtalk.com/document/orgapp-server/custom-robot-access
class DingTalkGateway implements Gateway {
  DingTalkGateway({
    required this.accessToken,
    this.secret,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String accessToken;
  final String? secret;
  final http.Client? httpClient;
  final Duration timeout;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'dingtalk';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (DingTalk is primarily outbound via webhooks).
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

  /// Generate signature for DingTalk webhook security.
  ///
  /// DingTalk requires a signature when a secret is configured.
  String _generateSignature(int timestamp) {
    if (secret == null || secret!.isEmpty) {
      return '';
    }
    final stringToSign = '$timestamp\n$secret';
    final bytes = utf8.encode(stringToSign);
    final digest = Hmac(sha256, bytes);
    return base64.encode(digest.bytes);
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final signature = _generateSignature(timestamp);

      // Extract optional metadata
      final atMobiles = m.meta['at_mobiles'] as List<String>?;
      final atAll = m.meta['at_all'] as bool? ?? false;

      // Build the message payload
      final payload = {
        'msgtype': 'text',
        'text': {
          'content': m.text,
        },
        if (atMobiles != null && atMobiles.isNotEmpty) 'at': {
          'atMobiles': atMobiles,
          'isAtAll': atAll,
        },
      };

      // Build URL with access token
      final url = Uri.parse('https://oapi.dingtalk.com/robot/send?access_token=$accessToken');

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      // Add signature headers if secret is configured
      if (signature.isNotEmpty) {
        headers['X-DingTalk-Signature'] = signature;
        headers['X-DingTalk-Timestamp'] = timestamp.toString();
      }

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400 || responseData['errcode'] != 0) {
        final errorMsg = responseData['errmsg'] as String? ?? response.body;
        throw StateError(
          'DingTalk API error: HTTP ${response.statusCode} - $errorMsg',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a markdown message to DingTalk.
  Future<void> sendMarkdown(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final signature = _generateSignature(timestamp);

      // Extract optional metadata
      final atMobiles = m.meta['at_mobiles'] as List<String>?;
      final atAll = m.meta['at_all'] as bool? ?? false;

      // Build the markdown payload
      final payload = {
        'msgtype': 'markdown',
        'markdown': {
          'title': m.meta['title'] as String? ?? 'Tiko-Agent Notification',
          'text': m.text,
        },
        if (atMobiles != null && atMobiles.isNotEmpty) 'at': {
          'atMobiles': atMobiles,
          'isAtAll': atAll,
        },
      };

      // Build URL with access token
      final url = Uri.parse('https://oapi.dingtalk.com/robot/send?access_token=$accessToken');

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };

      // Add signature headers if secret is configured
      if (signature.isNotEmpty) {
        headers['X-DingTalk-Signature'] = signature;
        headers['X-DingTalk-Timestamp'] = timestamp.toString();
      }

      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400 || responseData['errcode'] != 0) {
        final errorMsg = responseData['errmsg'] as String? ?? response.body;
        throw StateError(
          'DingTalk API error: HTTP ${response.statusCode} - $errorMsg',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // DingTalk doesn't support typing indicators
  }

  @override
  Future<void> sendStreamChunk(String sessionKey, String chunk) async {
    // DingTalk doesn't support streaming
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
