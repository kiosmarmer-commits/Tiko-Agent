import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// WeCom (企业微信) gateway for sending messages to WeChat Work.
///
/// WeCom is the enterprise version of WeChat, widely used in Chinese businesses.
/// This gateway supports sending messages via the API.
///
/// Configuration:
/// - corpId: Corporation ID from WeCom
/// - agentId: Agent ID (application ID)
/// - secret: Agent secret (for getting access token)
///
/// Reference: https://developer.work.weixin.qq.com/document/path/90236
class WeComGateway implements Gateway {
  WeComGateway({
    required this.corpId,
    required this.agentId,
    required this.secret,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String corpId;
  final String agentId;
  final String secret;
  final http.Client? httpClient;
  final Duration timeout;

  String? _accessToken;
  DateTime? _tokenExpiry;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'wecom';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (WeCom is primarily outbound via webhooks).
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

  /// Get or refresh the access token.
  Future<String> _getAccessToken() async {
    // Return cached token if still valid
    if (_accessToken != null && _tokenExpiry != null) {
      if (DateTime.now().isBefore(_tokenExpiry!)) {
        return _accessToken!;
      }
    }

    final client = httpClient ?? http.Client();
    try {
      final url = Uri.parse(
        'https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=$corpId&corpsecret=$secret',
      );

      final response = await client
          .get(url)
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != 0) {
        throw StateError(
          'WeCom token error: ${responseData['errmsg']}',
        );
      }

      _accessToken = responseData['access_token'] as String;
      // Token expires in 7200 seconds (2 hours)
      _tokenExpiry = DateTime.now().add(const Duration(seconds: 7200));

      return _accessToken!;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final token = await _getAccessToken();

      // Extract optional metadata
      final userIds = m.meta['user_ids'] as List<String>?;
      final partyIds = m.meta['party_ids'] as List<String>?;
      final tagIds = m.meta['tag_ids'] as List<String>?;

      // Build the message payload
      final payload = {
        'touser': userIds?.join('|') ?? '',
        'toparty': partyIds?.join('|') ?? '',
        'totag': tagIds?.join('|') ?? '',
        'msgtype': 'text',
        'agentid': agentId,
        'text': {
          'content': m.text,
        },
        'safe': 0, // 0 = plain text, 1 = safe mode
      };

      // Remove empty values
      payload.removeWhere((key, value) => value == '');

      final url = Uri.parse(
        'https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$token',
      );

      final response = await client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != 0) {
        throw StateError(
          'WeCom API error: ${responseData['errmsg']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a markdown message to WeCom.
  Future<void> sendMarkdown(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final token = await _getAccessToken();

      // Extract optional metadata
      final userIds = m.meta['user_ids'] as List<String>?;
      final partyIds = m.meta['party_ids'] as List<String>?;
      final tagIds = m.meta['tag_ids'] as List<String>?;

      // Build the markdown payload
      final payload = {
        'touser': userIds?.join('|') ?? '',
        'toparty': partyIds?.join('|') ?? '',
        'totag': tagIds?.join('|') ?? '',
        'msgtype': 'markdown',
        'agentid': agentId,
        'markdown': {
          'content': m.text,
        },
        'safe': 0,
      };

      // Remove empty values
      payload.removeWhere((key, value) => value == '');

      final url = Uri.parse(
        'https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$token',
      );

      final response = await client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != 0) {
        throw StateError(
          'WeCom API error: ${responseData['errmsg']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // WeCom doesn't support typing indicators
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
