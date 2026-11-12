import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'text_split.dart';

/// Matrix gateway via the client-server API v3 (`/_matrix/client/v3`).
///
/// Long-polls `GET /sync` and sends messages with
/// `PUT /rooms/{roomId}/send/m.room.message/{txnId}`. Only events from
/// rooms in [allowedRooms] (room ids) produce inbound messages.
class MatrixGateway implements Gateway {
  MatrixGateway({
    required this.homeserverUrl,
    required this.accessToken,
    required this.allowedRooms,
    this.client,
    this.syncTimeoutMs = 30000,
  })  : assert(
          homeserverUrl.startsWith('http://') || homeserverUrl.startsWith('https://'),
          'homeserverUrl harus http(s)',
        ),
        assert(allowedRooms.isNotEmpty, 'allowedRooms wajib diisi');

  final String homeserverUrl;
  final String accessToken;
  final Set<String> allowedRooms;
  final http.Client? client;
  final int syncTimeoutMs;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _seenEvents = <String>{};
  bool _running = false;
  String? _since;
  int _txnCounter = 0;
  final Random _rng = Random();

  @override
  String get channel => 'matrix';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  http.Client get _client => client ?? http.Client();

  Uri _v3(String path, [Map<String, String>? query]) => Uri.parse(
        '${homeserverUrl.replaceAll(RegExp(r'/+$'), '')}/_matrix/client/v3$path',
      ).replace(queryParameters: query);

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  /// Start the sync loop.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_syncLoop());
  }

  Future<void> stop() async {
    _running = false;
  }

  Future<void> _syncLoop() async {
    while (_running) {
      try {
        final uri = _v3('/sync', {
          'timeout': '$syncTimeoutMs',
          if (_since != null) 'since': _since!,
        });
        final res = await _client
            .get(uri, headers: _authHeaders)
            .timeout(Duration(milliseconds: syncTimeoutMs + 15000));
        if (res.statusCode != 200) {
          throw StateError('matrix sync HTTP ${res.statusCode}');
        }
        final map = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
        if (map is Map<String, dynamic>) {
          _since = map['next_batch']?.toString() ?? _since;
          _handleSync(map);
        }
      } catch (_) {
        if (_running) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  void _handleSync(Map<String, dynamic> sync) {
    final rooms = sync['rooms'];
    if (rooms is! Map<String, dynamic>) return;
    final joinSections = <String, dynamic>{
      ...?rooms['join'] as Map<String, dynamic>?,
      ...?rooms['invite'] as Map<String, dynamic>?,
    };
    for (final entry in joinSections.entries) {
      final roomId = entry.key;
      if (!allowedRooms.contains(roomId)) continue;
      final section = entry.value;
      if (section is! Map<String, dynamic>) continue;
      final timeline = section['timeline'] as Map<String, dynamic>?;
      final events = timeline?['events'] as List<dynamic>?;
      if (events == null) continue;
      for (final event in events) {
        if (event is! Map<String, dynamic>) continue;
        _handleRoomEvent(roomId, event);
      }
    }
  }

  void _handleRoomEvent(String roomId, Map<String, dynamic> event) {
    if (event['type'] != 'm.room.message') return;
    final eventId = event['event_id']?.toString() ?? '';
    if (eventId.isEmpty || !_seenEvents.add(eventId)) return;
    if (_seenEvents.length > 4096) _seenEvents.clear();
    final content = event['content'];
    if (content is! Map<String, dynamic>) return;
    if (content['msgtype'] != 'm.text') return;
    final text = content['body']?.toString() ?? '';
    if (text.trim().isEmpty) return;
    final sender = event['sender']?.toString() ?? '';
    _inbound.add(InboundMessage(
      channel: channel,
      userKey: sender,
      sessionKey: 'matrix:$roomId',
      text: text,
      meta: {'event_id': eventId, 'origin_server_ts': event['origin_server_ts']},
    ));
  }

  String? _roomFromSession(String sessionKey) {
    if (!sessionKey.startsWith('matrix:')) return null;
    final room = sessionKey.substring('matrix:'.length);
    return room.isEmpty ? null : room;
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final roomId = _roomFromSession(m.sessionKey);
    if (roomId == null) {
      throw ArgumentError('sessionKey matrix tidak valid: ${m.sessionKey}');
    }
    for (final part in splitMessage(m.text)) {
      _txnCounter += 1;
      final txn =
          'tiko-${DateTime.now().millisecondsSinceEpoch}-$_txnCounter-${_rng.nextInt(1 << 32)}';
      final encoded = Uri.encodeComponent(roomId);
      final res = await _client
          .put(
            _v3('/rooms/$encoded/send/m.room.message/$txn'),
            headers: _authHeaders,
            body: jsonEncode({'msgtype': 'm.text', 'body': part}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw StateError('matrix send HTTP ${res.statusCode}: ${res.body}');
      }
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    final roomId = _roomFromSession(sessionKey);
    if (roomId == null) return;
    try {
      final encoded = Uri.encodeComponent(roomId);
      await _client
          .put(
            _v3('/rooms/$encoded/typing/tiko-agent'),
            headers: _authHeaders,
            body: jsonEncode({'typing': true, 'timeout': 5000}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Typing indicator is best-effort.
    }
  }

  @override
  Future<void> close() async {
    _running = false;
    await _inbound.close();
  }
}
