import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Progressive streaming bridge (P1-4, Hermes-parity): one live chat message
/// is created up front and edited in place as model tokens arrive, throttled
/// to respect platform rate limits. Overflow beyond [maxLen] is finalized and
/// a fresh live message continues the answer.
///
/// Edits are best-effort: a failed edit never aborts the underlying turn.
class ProgressiveStreamer {
  ProgressiveStreamer({
    required Future<String> Function(String text) create,
    required Future<void> Function(String id, String text) update,
    this.minInterval = const Duration(seconds: 2),
    this.maxLen = 3500,
  })  : _create = create,
        _update = update;

  final Future<String> Function(String text) _create;
  final Future<void> Function(String id, String text) _update;
  final Duration minInterval;
  final int maxLen;

  final _buffer = StringBuffer();
  final List<String> _finishedIds = [];
  String? _liveId;
  Timer? _timer;
  bool _dirty = false;

  /// Number of finalized (overflow) message ids so far.
  List<String> get finishedIds => List.unmodifiable(_finishedIds);

  /// Feed one sanitized delta. Never throws.
  void add(String delta) {
    if (delta.isEmpty) return;
    _buffer.write(delta);
    _dirty = true;
    _timer ??= Timer(minInterval, _flush);
  }

  void _flush() {
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    unawaited(_editNow());
  }

  Future<void> _editNow() async {
    try {
      await _ensureLive();
      final id = _liveId;
      if (id == null) return;
      final text = _takeEditable();
      if (text.isEmpty) return;
      await _update(id, text);
    } catch (_) {
      // Platform rate limit or transient network error: keep buffering and
      // retry on the next throttle tick or at finish().
    }
  }

  String _takeEditable() {
    final s = _buffer.toString();
    if (s.length <= maxLen) return s;
    return s.substring(s.length - maxLen);
  }

  Future<void> _ensureLive() async {
    if (_liveId != null) return;
    final head = _buffer.toString();
    _liveId = await _create(head.isEmpty ? '…' : head);
    _dirty = false;
  }

  /// Finalize the stream: replace the live message with the final (already
  /// sanitized) text, spilling overflow into follow-up messages. Returns all
  /// message ids in order (finished overflow + the last live message).
  Future<List<String>> finish(String finalText) async {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    final ids = <String>[..._finishedIds];
    var rest = finalText;
    try {
      while (true) {
        await _ensureLive();
        final id = _liveId!;
        if (rest.length <= maxLen) {
          await _update(id, rest.isEmpty ? '…' : rest);
          ids.add(id);
          _liveId = null;
          break;
        }
        final head = rest.substring(0, maxLen);
        await _update(id, head);
        ids.add(id);
        _liveId = null;
        rest = rest.substring(maxLen);
        _finishedIds.clear();
      }
    } catch (_) {
      // Leave the last known good edit in place; caller falls back to a
      // plain send() for anything unsent.
    }
    return ids;
  }
}

/// Telegram adapter: sendMessage -> editMessageText (rate-limit friendly at
/// ~1 edit/2s per chat).
class TelegramLiveMessage {
  TelegramLiveMessage({required this.token, required this.chatId, this.httpClient});
  final String token;
  final String chatId;
  final http.Client? httpClient;

  Uri _api(String method) =>
      Uri.parse('https://api.telegram.org/bot$token/$method');

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> body,
  ) async {
    final client = httpClient ?? http.Client();
    try {
      final res = await client.post(
        _api(method),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['ok'] != true) {
        throw StateError('Telegram API error: ${res.body}');
      }
      return json;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<String> create(String text) async {
    final json = await _post('sendMessage', {
      'chat_id': chatId,
      'text': text,
    });
    return '${(json['result'] as Map)['message_id']}';
  }

  Future<void> update(String messageId, String text) => _post(
        'editMessageText',
        {'chat_id': chatId, 'message_id': int.parse(messageId), 'text': text},
      );
}

/// Discord adapter: POST message -> PATCH message (max ~5 edits/5s per
/// channel; 1.2s throttle is safe).
class DiscordLiveMessage {
  DiscordLiveMessage({
    required this.botToken,
    required this.channelId,
    this.httpClient,
  });
  final String botToken;
  final String channelId;
  final http.Client? httpClient;

  Future<Map<String, dynamic>> _call(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final client = httpClient ?? http.Client();
    try {
      final req = http.Request(
        method,
        Uri.parse('https://discord.com/api/v10$path'),
      )
        ..headers['Authorization'] = 'Bot $botToken'
        ..headers['Content-Type'] = 'application/json';
      if (body != null) req.body = jsonEncode(body);
      final res = await client.send(req).then(http.Response.fromStream);
      if (res.statusCode >= 300) {
        throw StateError('Discord API error ${res.statusCode}: ${res.body}');
      }
      if (res.body.isEmpty) return const {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<String> create(String text) => _call(
        'POST',
        '/channels/$channelId/messages',
        {'content': text},
      ).then((json) => '${json['id']}');

  Future<void> update(String messageId, String text) => _call(
        'PATCH',
        '/channels/$channelId/messages/$messageId',
        {'content': text},
      );
}
