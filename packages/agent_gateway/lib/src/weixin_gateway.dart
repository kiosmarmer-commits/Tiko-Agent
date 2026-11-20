import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Weixin (微信) Official Account gateway for sending messages.
///
/// This gateway supports sending messages via WeChat Official Account API.
/// Note: This requires a verified WeChat Official Account.
///
/// Configuration:
/// - appId: Official Account App ID
/// - appSecret: Official Account App Secret
///
/// Reference: https://developers.weixin.qq.com/doc/offiaccount/Message_Management/Service_Center_messages.html
class WeixinGateway implements Gateway {
  WeixinGateway({
    required this.appId,
    required this.appSecret,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
  });

  final String appId;
  final String appSecret;
  final http.Client? httpClient;
  final Duration timeout;

  String? _accessToken;
  DateTime? _tokenExpiry;

  final _inbound = StreamController<InboundMessage>.broadcast();

  @override
  String get channel => 'weixin';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Push an inbound message (Weixin can receive messages via webhooks).
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
        'https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=$appId&secret=$appSecret',
      );

      final response = await client
          .get(url)
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != null) {
        throw StateError(
          'Weixin token error: ${responseData['errmsg']}',
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

      // Extract openid from metadata (required for Weixin)
      final openid = m.meta['openid'] as String?;
      if (openid == null || openid.isEmpty) {
        throw StateError('Weixin requires openid in message metadata');
      }

      // Build the text message payload
      final payload = {
        'touser': openid,
        'msgtype': 'text',
        'text': {
          'content': m.text,
        },
      };

      final url = Uri.parse(
        'https://api.weixin.qq.com/cgi-bin/message/custom/send?access_token=$token',
      );

      final response = await client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != null && responseData['errcode'] != 0) {
        throw StateError(
          'Weixin API error: ${responseData['errmsg']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send a news message to Weixin.
  Future<void> sendNews(OutboundMessage m) async {
    final client = httpClient ?? http.Client();
    try {
      final token = await _getAccessToken();

      // Extract openid from metadata
      final openid = m.meta['openid'] as String?;
      if (openid == null || openid.isEmpty) {
        throw StateError('Weixin requires openid in message metadata');
      }

      // Parse text as news articles (format: "Title1: Content1\n\nTitle2: Content2")
      final articles = _parseNewsText(m.text);

      // Build the news message payload
      final payload = {
        'touser': openid,
        'msgtype': 'news',
        'news': {
          'articles': articles,
        },
      };

      final url = Uri.parse(
        'https://api.weixin.qq.com/cgi-bin/message/custom/send?access_token=$token',
      );

      final response = await client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseData['errcode'] != null && responseData['errcode'] != 0) {
        throw StateError(
          'Weixin API error: ${responseData['errmsg']}',
        );
      }
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Parse text into news articles.
  /// Format: "Title: Content" separated by double newlines.
  List<Map<String, String>> _parseNewsText(String text) {
    final articles = <Map<String, String>>[];
    final parts = text.split('\n\n');

    for (final part in parts) {
      if (part.trim().isEmpty) continue;
      final colonIndex = part.indexOf(':');
      if (colonIndex > 0) {
        final title = part.substring(0, colonIndex).trim();
        final content = part.substring(colonIndex + 1).trim();
        articles.add({
          'title': title,
          'description': content,
          'url': '', // URL is required but can be empty placeholder
          'picurl': '', // Pic URL is optional
        });
      } else {
        // No colon, treat as single article
        articles.add({
          'title': 'Notification',
          'description': part.trim(),
          'url': '',
          'picurl': '',
        });
      }
    }

    // If no articles parsed, create a default one
    if (articles.isEmpty) {
      articles.add({
        'title': 'Notification',
        'description': text,
        'url': '',
        'picurl': '',
      });
    }

    return articles;
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    // Weixin doesn't support typing indicators
  }

  @override
  Future<void> sendStreamChunk(String sessionKey, String chunk) async {
    // Weixin doesn't support streaming
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}
