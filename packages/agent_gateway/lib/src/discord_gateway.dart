import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Discord gateway: webhook outbound + Bot Gateway WebSocket inbound (AGD-05).
class DiscordGateway implements Gateway {
  DiscordGateway({
    this.webhookUrl,
    this.botToken,
    this.allowedUserIds = const {},
    this.applicationId,
    this.registerSlash = true,
    http.Client? httpClient,
  }) : _client = httpClient;

  final String? webhookUrl;
  final String? botToken;
  final Set<String> allowedUserIds;
  final String? applicationId;
  final bool registerSlash;
  final http.Client? _client;

  final _inbound = StreamController<InboundMessage>.broadcast();
  WebSocket? _ws;
  Timer? _heartbeat;
  int? _heartbeatIntervalMs;
  int? _seq;
  bool _running = false;
  String? _applicationId;

  @override
  String get channel => 'discord';

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  /// Start Discord Gateway WS (requires botToken).
  Future<void> start() async {
    if (botToken == null || botToken!.isEmpty) return;
    if (_running) return;
    _running = true;
    await _connect();
  }

  Future<void> _connect() async {
    // Get gateway URL
    final client = _client ?? http.Client();
    String url;
    try {
      final res = await client.get(
        Uri.parse('https://discord.com/api/v10/gateway'),
        headers: {'Authorization': 'Bot $botToken'},
      );
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      url = '${json['url']}?v=10&encoding=json';
    } finally {
      if (_client == null) client.close();
    }

    _ws = await WebSocket.connect(url);
    _ws!.listen(_onEvent, onDone: _onDone, onError: (_) => _onDone());
  }

  void _onEvent(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final op = msg['op'] as int?;
      final t = msg['t'] as String?;
      final s = msg['s'] as int?;
      if (s != null) _seq = s;
      final d = msg['d'];

      switch (op) {
        case 10: // Hello
          final interval = (d as Map)['heartbeat_interval'] as int;
          _heartbeatIntervalMs = interval;
          _startHeartbeat();
          _identify();
          break;
        case 0: // Dispatch
          if (t == 'READY') {
            final dm = d as Map;
            _applicationId =
                applicationId ?? (dm['application'] as Map?)?['id']?.toString();
            if (registerSlash && _applicationId != null) {
              // ignore: discarded_futures
              _registerSlashCommands();
            }
          } else if (t == 'MESSAGE_CREATE') {
            _onMessageCreate(d as Map<String, dynamic>);
          } else if (t == 'INTERACTION_CREATE') {
            _onInteraction(d as Map<String, dynamic>);
          }
          break;
        case 11: // Heartbeat ACK
          break;
        case 7: // Reconnect
          _reconnect();
          break;
        case 9: // Invalid session
          Future.delayed(const Duration(seconds: 3), _identify);
          break;
      }
    } catch (_) {}
  }

  void _identify() {
    _ws?.add(
      jsonEncode({
        'op': 2,
        'd': {
          'token': botToken,
          'intents':
              1 | 512 | 32768, // GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT
          'properties': {
            'os': Platform.operatingSystem,
            'browser': 'agent_dart',
            'device': 'agent_dart',
          },
        },
      }),
    );
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    final ms = _heartbeatIntervalMs ?? 41250;
    _heartbeat = Timer.periodic(Duration(milliseconds: ms), (_) {
      _ws?.add(jsonEncode({'op': 1, 'd': _seq}));
    });
  }

  void _onMessageCreate(Map<String, dynamic> d) {
    if (d['author'] is Map && (d['author'] as Map)['bot'] == true) return;
    final author = d['author'] as Map<String, dynamic>? ?? {};
    final uid = '${author['id']}';
    if (allowedUserIds.isNotEmpty && !allowedUserIds.contains(uid)) return;
    final content = d['content'] as String? ?? '';
    if (content.isEmpty) return;
    final channelId = '${d['channel_id']}';
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: uid,
        sessionKey: 'discord:$channelId',
        text: content,
        meta: {
          'username': author['username'],
          'channel_id': channelId,
          'message_id': '${d['id']}',
        },
      ),
    );
  }

  void _onDone() {
    _heartbeat?.cancel();
    if (_running) {
      Future.delayed(const Duration(seconds: 5), () {
        if (_running) _connect();
      });
    }
  }

  Future<void> _reconnect() async {
    await _ws?.close();
    await _connect();
  }

  void pushMessage({
    required String userId,
    required String text,
    String? channelId,
    String? username,
  }) {
    if (allowedUserIds.isNotEmpty && !allowedUserIds.contains(userId)) return;
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: userId,
        sessionKey: 'discord:${channelId ?? userId}',
        text: text,
        meta: {'username': username, 'channel_id': channelId},
      ),
    );
  }

  Future<void> _registerSlashCommands() async {
    final appId = _applicationId ?? applicationId;
    if (botToken == null || appId == null || appId.isEmpty) return;
    final client = _client ?? http.Client();
    try {
      await client.put(
        Uri.parse('https://discord.com/api/v10/applications/$appId/commands'),
        headers: {
          'Authorization': 'Bot $botToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode([
          {
            'name': 'agent',
            'description': 'Kirim pesan ke agent',
            'type': 1,
            'options': [
              {
                'name': 'message',
                'description': 'Pesan untuk agent',
                'type': 3,
                'required': true,
              },
            ],
          },
        ]),
      );
    } catch (_) {
      // Registration is best effort; normal message events remain usable.
    } finally {
      if (_client == null) client.close();
    }
  }

  void _onInteraction(Map<String, dynamic> d) {
    final user =
        (d['member'] as Map?)?['user'] as Map? ?? d['user'] as Map? ?? {};
    final userId = '${user['id'] ?? ''}';
    if (userId.isEmpty ||
        (allowedUserIds.isNotEmpty && !allowedUserIds.contains(userId))) {
      return;
    }
    final data = d['data'] as Map<String, dynamic>? ?? {};
    final name = data['name'] as String? ?? 'agent';
    final options = data['options'] as List<dynamic>? ?? [];
    final message = options
        .whereType<Map>()
        .where((o) => o['name'] == 'message')
        .map((o) => o['value']?.toString() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '/$name');
    final channelId = '${d['channel_id'] ?? userId}';
    _inbound.add(
      InboundMessage(
        channel: channel,
        userKey: userId,
        sessionKey: 'discord:$channelId',
        text: message,
        meta: {
          'username': user['username'],
          'channel_id': channelId,
          'interaction_id': d['id'],
        },
      ),
    );
  }

  @override
  Future<void> send(OutboundMessage m) async {
    final text = m.text.length > 1900
        ? '${m.text.substring(0, 1900)}…'
        : m.text;

    // Prefer channel message via Bot API if channel_id in session
    final channelId = m.sessionKey.startsWith('discord:')
        ? m.sessionKey.substring('discord:'.length)
        : null;

    if (botToken != null && channelId != null && channelId.isNotEmpty) {
      final client = _client ?? http.Client();
      try {
        await client.post(
          Uri.parse('https://discord.com/api/v10/channels/$channelId/messages'),
          headers: {
            'Authorization': 'Bot $botToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'content': text}),
        );
        return;
      } finally {
        if (_client == null) client.close();
      }
    }

    if (webhookUrl != null && webhookUrl!.isNotEmpty) {
      final client = _client ?? http.Client();
      try {
        await client.post(
          Uri.parse(webhookUrl!),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'content': text}),
        );
      } finally {
        if (_client == null) client.close();
      }
    }
  }

  @override
  Future<void> sendTyping(String sessionKey) async {
    final channelId = sessionKey.startsWith('discord:')
        ? sessionKey.substring('discord:'.length)
        : null;
    if (botToken == null || channelId == null) return;
    final client = _client ?? http.Client();
    try {
      await client.post(
        Uri.parse('https://discord.com/api/v10/channels/$channelId/typing'),
        headers: {'Authorization': 'Bot $botToken'},
      );
    } catch (_) {
    } finally {
      if (_client == null) client.close();
    }
  }


  @override

  Future<void> close() async {
    _running = false;
    _heartbeat?.cancel();
    await _ws?.close();
    await _inbound.close();
  }
}
