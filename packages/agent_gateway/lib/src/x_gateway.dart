import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Fase 42 — X (Twitter) gateway (paritas Grok Bot @grok di X): polling
/// mentions X API v2 + balasan tweet. Deterministik dan dapat diuji:
/// `apiBase` + `httpClient` dapat diinjeksi sehingga test memakai server
/// lokal, tanpa jaringan nyata.
///
/// Konvensi repo:
/// - Fail-closed di wiring: daemon wajib mengatur allowlist author id;
///   di level gateway, allowlist kosong berarti drop semua mention
///   (platform publik — mention dari siapa pun tidak boleh membakar LLM).
/// - Dedupe tweet id (bounded) + `since_id` progresif agar polling
///   restart tidak memproses ulang.
class XGateway implements Gateway {
  XGateway({
    required this.bearerToken,
    required this.botUserId,
    this.allowedUserIds = const <String>{},
    this.apiBase = 'https://api.x.com/2',
    this.pollIntervalSec = 60,
    this.maxResults = 25,
    this.maxTweetChars = 280,
    this.maxSeenIds = 2048,
    http.Client? httpClient,
  }) : _client = httpClient;

  final String bearerToken;
  final String botUserId;
  final Set<String> allowedUserIds;
  final String apiBase;
  final int pollIntervalSec;
  final int maxResults;
  final int maxTweetChars;
  final int maxSeenIds;
  final http.Client? _client;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _seenTweetIds = <String>{};
  bool _running = false;
  Timer? _pollTimer;
  String? _sinceId;

  @override
  String get channel => 'x';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  bool get running => _running;

  /// Mulai loop polling mentions.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_pollLoop());
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
  }

  Uri _mentionsUri() {
    final params = <String, String>{
      'max_results': '$maxResults',
      'tweet.fields': 'conversation_id,author_id,in_reply_to_user_id',
    };
    if (_sinceId != null) params['since_id'] = _sinceId!;
    return Uri.parse('$apiBase/users/$botUserId/mentions')
        .replace(queryParameters: params);
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final json = await _getJson(_mentionsUri());
        final data = json['data'] as List<dynamic>? ?? const [];
        String? newestId = _sinceId;
        for (final raw in data) {
          if (raw is! Map) continue;
          final tweetId = raw['id']?.toString() ?? '';
          if (tweetId.isEmpty) continue;
          if (newestId == null || _idGreater(tweetId, newestId)) {
            newestId = tweetId;
          }
          if (_seenTweetIds.contains(tweetId)) continue;
          _remember(tweetId);
          final authorId = raw['author_id']?.toString() ?? '';
          final text = raw['text']?.toString() ?? '';
          if (!_allowed(authorId) || text.isEmpty) continue;
          final conversationId = raw['conversation_id']?.toString() ?? tweetId;
          _inbound.add(InboundMessage(
            channel: channel,
            userKey: 'x:$authorId',
            sessionKey: 'x:$conversationId',
            text: text,
            meta: {
              'tweet_id': tweetId,
              'author_id': authorId,
              'conversation_id': conversationId,
            },
          ));
        }
        if (newestId != null) _sinceId = newestId;
      } catch (_) {
        // Polling best-effort; kegagalan jaringan tidak menghentikan loop.
      }
      await Future<void>.delayed(Duration(seconds: pollIntervalSec));
    }
  }

  /// Komparasi id numerik X (snowflake) tanpa parse besar-besar.
  bool _idGreater(String a, String b) {
    if (a.length != b.length) return a.length > b.length;
    return a.compareTo(b) > 0;
  }

  void _remember(String tweetId) {
    _seenTweetIds.add(tweetId);
    while (_seenTweetIds.length > maxSeenIds) {
      _seenTweetIds.remove(_seenTweetIds.first);
    }
  }

  /// Allowlist kosong = drop semua (fail-closed, platform publik).
  bool _allowed(String authorId) =>
      authorId.isNotEmpty && allowedUserIds.contains(authorId);

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = _client ?? http.Client();
    try {
      final res = await client
          .get(uri, headers: {'Authorization': 'Bearer $bearerToken'})
          .timeout(Duration(seconds: pollIntervalSec + 15));
      if (res.statusCode != 200) {
        throw StateError('X API error ${res.statusCode}');
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      if (_client == null) client.close();
    }
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final tweetId = m.sessionKey.startsWith('x:') &&
            !m.sessionKey.startsWith('x:dm:')
        ? m.sessionKey.substring('x:'.length)
        : '';
    final text = m.text.length > maxTweetChars
        ? '${m.text.substring(0, maxTweetChars - 1)}…'
        : m.text;
    final body = <String, dynamic>{
      'text': text,
      if (tweetId.isNotEmpty)
        'reply': {'in_reply_to_tweet_id': tweetId},
    };
    final client = _client ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('$apiBase/tweets'),
            headers: {
              'Authorization': 'Bearer $bearerToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('X API send error ${res.statusCode}');
      }
    } finally {
      if (_client == null) client.close();
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {}

  @override
  Future<void> close() async {
    await stop();
    await _inbound.close();
  }
}
