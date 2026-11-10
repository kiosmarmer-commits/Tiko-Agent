import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Abstraction over the voice gateway WebSocket so tests can inject fakes.
abstract class VoiceSocket {
  void add(Object data);

  Stream<dynamic> get stream;

  Future<void> close();
}

/// Production adapter around dart:io [WebSocket].
class IoVoiceSocket implements VoiceSocket {
  IoVoiceSocket(this._ws);

  final WebSocket _ws;

  @override
  void add(Object data) => _ws.add(data);

  @override
  Stream<dynamic> get stream => _ws;

  @override
  Future<void> close() => _ws.close();
}

/// Abstraction over the voice UDP transport so tests can inject fakes.
abstract class VoiceUdpSocket {
  Future<int> send(List<int> buffer, InternetAddress address, int port);

  Stream<Datagram> get stream;

  Future<void> close();
}

/// Production adapter around dart:io [RawDatagramSocket].
class IoVoiceUdpSocket implements VoiceUdpSocket {
  IoVoiceUdpSocket._(this._socket);

  final RawDatagramSocket _socket;

  static Future<VoiceUdpSocket> bind(InternetAddress host, int port) async {
    final raw = await RawDatagramSocket.bind(host, port);
    return IoVoiceUdpSocket._(raw);
  }

  @override
  Future<int> send(List<int> buffer, InternetAddress address, int port) async =>
      _socket.send(buffer, address, port) ?? 0;

  @override
  Stream<Datagram> get stream => _socket;

  @override
  Future<void> close() async => _socket.close();
}

/// RTP payload encryptor for Discord voice (pluggable).
abstract class VoiceEncryptor {
  /// The `mode` value advertised in the op 4 Select Protocol payload.
  String get mode;

  /// Encrypts [payload] (already prefixed with the RTP header) using [nonce].
  List<int> encrypt(List<int> payload, List<int> nonce);
}

/// Placeholder for the mandatory `xsalsa20_poly1305` mode.
///
/// Pure Dart cannot produce a TweetNaCl xsalsa20-poly1305 box without an
/// extra dependency, so this encryptor throws; supply a custom
/// [VoiceEncryptor] (e.g. backed by an FFI sodium build) to transmit audio.
class UnsupportedVoiceEncryptor implements VoiceEncryptor {
  const UnsupportedVoiceEncryptor();

  @override
  String get mode => 'xsalsa20_poly1305';

  @override
  List<int> encrypt(List<int> payload, List<int> nonce) {
    throw UnsupportedError(
      'xsalsa20_poly1305 tidak tersedia; sediakan VoiceEncryptor kustom.',
    );
  }
}

/// Voice state assembled from VOICE_STATE_UPDATE + VOICE_SERVER_UPDATE.
class DiscordVoiceState {
  String? sessionId;
  String? userId;
  String? token;
  String? endpoint;
  String? guildId;
}

/// Result of the UDP IP-discovery handshake.
class VoiceUdpDiscovery {
  const VoiceUdpDiscovery({required this.ip, required this.port});

  final String ip;
  final int port;
}

typedef WebSocketFactory = Future<VoiceSocket> Function(Uri url);
typedef UdpSocketFactory = Future<VoiceUdpSocket> Function(
  InternetAddress host,
  int port,
);

/// Config for [DiscordVoiceClient].
class DiscordVoiceConfig {
  const DiscordVoiceConfig({
    required this.botToken,
    required this.guildId,
    required this.channelId,
    this.apiBaseUrl = 'https://discord.com/api/v10',
    this.gatewayUrl = 'wss://gateway.discord.gg/?v=10&encoding=json',
    this.selfDeaf = true,
    this.selfMute = false,
    this.timeout = const Duration(seconds: 15),
    this.wsFactory = _defaultWsFactory,
    this.udpFactory = IoVoiceUdpSocket.bind,
    this.encryptor = const UnsupportedVoiceEncryptor(),
  });

  final String botToken;
  final String guildId;
  final String channelId;
  final String apiBaseUrl;
  final String gatewayUrl;
  final bool selfDeaf;
  final bool selfMute;
  final Duration timeout;
  final WebSocketFactory wsFactory;
  final UdpSocketFactory udpFactory;
  final VoiceEncryptor encryptor;

  static Future<VoiceSocket> _defaultWsFactory(Uri url) async =>
      IoVoiceSocket(await WebSocket.connect(url.toString()));
}

/// Discord voice gateway client (op 0 Identify / op 2 Ready / op 4 Select
/// Protocol / op 5 Speaking / op 6 Session Description) plus the UDP IP
/// discovery protocol (74-byte packet, big-endian port trailer).
///
/// The main (text) gateway must forward VOICE_STATE_UPDATE and
/// VOICE_SERVER_UPDATE dispatches to [handleDispatch] so [join] can assemble
/// the voice credentials.
class DiscordVoiceClient {
  DiscordVoiceClient({required this.config, http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  final DiscordVoiceConfig config;
  final http.Client _client;

  VoiceSocket? _ws;
  VoiceUdpSocket? _udp;
  Timer? _heartbeat;
  final _state = DiscordVoiceState();
  final _voiceState = Completer<Map<String, dynamic>>();
  final _voiceServer = Completer<Map<String, dynamic>>();
  Completer<Map<String, dynamic>>? _ready;
  Completer<Map<String, dynamic>>? _sessionDescription;
  int? _ssrc;
  String? _externalIp;
  int? _externalPort;
  bool _running = false;

  /// True once the op 6 Session Description was received.
  bool get isReady => _sessionDescription?.isCompleted ?? false;

  int? get ssrc => _ssrc;

  /// Feeds a main-gateway dispatch event (VOICE_STATE_UPDATE or
  /// VOICE_SERVER_UPDATE) into the client.
  void handleDispatch(String type, Map<String, dynamic> data) {
    if (type == 'VOICE_STATE_UPDATE' && !_voiceState.isCompleted) {
      _state.guildId = data['guild_id']?.toString();
      _state.userId = data['user_id']?.toString();
      _voiceState.complete(data);
    } else if (type == 'VOICE_SERVER_UPDATE' && !_voiceServer.isCompleted) {
      _voiceServer.complete(data);
    }
  }

  /// Joins the configured voice channel and completes the voice handshake.
  Future<void> join() async {
    if (_running) return;
    _running = true;
    try {
      await _patchVoiceState();
      final stateTimeout = Future.wait([
        _voiceState.future,
        _voiceServer.future,
      ]).timeout(config.timeout);
      final pair = await stateTimeout;
      _state.sessionId = pair[0]['session_id']?.toString();
      _state.token = pair[1]['token']?.toString();
      _state.endpoint = pair[1]['endpoint']?.toString();
      if (_state.sessionId == null ||
          _state.token == null ||
          _state.endpoint == null ||
          _state.endpoint!.isEmpty) {
        throw StateError('Kredensial voice tidak lengkap dari gateway utama');
      }

      final wsUri = Uri.parse(
        'wss://${_state.endpoint}?v=4&encoding=json',
      );
      final ws = await config.wsFactory(wsUri);
      _ws = ws;
      _ready = Completer<Map<String, dynamic>>();
      _sessionDescription = Completer<Map<String, dynamic>>();
      ws.stream.listen(_onMessage, onError: (_) {}, onDone: () {});

      final ready = await _ready!.future.timeout(config.timeout);
      _ssrc = (ready['ssrc'] as num?)?.toInt();
      final ip = ready['ip']?.toString() ?? '';
      final port = (ready['port'] as num?)?.toInt() ?? 0;

      final discovery = await _discoverUdp(ip, port);
      _selectProtocol(discovery);

      await _sessionDescription!.future.timeout(config.timeout);
    } catch (e) {
      _running = false;
      rethrow;
    }
  }

  Future<void> _patchVoiceState() async {
    final res = await _client
        .patch(
          Uri.parse('${config.apiBaseUrl}/guilds/${config.guildId}'
              '/voice-states/@me'),
          headers: {
            'authorization': 'Bot ${config.botToken}',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'channel_id': config.channelId,
            'self_deaf': config.selfDeaf,
            'self_mute': config.selfMute,
          }),
        )
        .timeout(config.timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Gagal join voice channel: HTTP ${res.statusCode} ${res.body}',
      );
    }
  }

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final op = (msg['op'] as num?)?.toInt();
      final d = msg['d'];
      switch (op) {
        case 10: // Hello
          final interval =
              ((d as Map)['heartbeat_interval'] as num?)?.toInt() ?? 13750;
          _startHeartbeat(interval);
          _identify();
          break;
        case 2: // Ready
          if (!(_ready?.isCompleted ?? true)) {
            _ready!.complete(d as Map<String, dynamic>);
          }
          break;
        case 6: // Session Description
          if (!(_sessionDescription?.isCompleted ?? true)) {
            _sessionDescription!.complete(d as Map<String, dynamic>);
          }
          break;
        case 5: // Speaking (others)
        case 3: // Heartbeat ACK
          break;
      }
    } catch (_) {}
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _ws?.add(jsonEncode({
        'op': 3,
        'd': null,
      }));
    });
  }

  void _identify() {
    _ws?.add(jsonEncode({
      'op': 0,
      'd': {
        'server_id': config.guildId,
        'user_id': _state.userId,
        'session_id': _state.sessionId,
        'token': _state.token,
      },
    }));
  }

  Future<VoiceUdpDiscovery> _discoverUdp(String ip, int port) async {
    final address = InternetAddress.tryParse(ip);
    if (address == null) {
      throw StateError('Alamat UDP voice tidak valid: $ip');
    }
    final udp = await config.udpFactory(InternetAddress.anyIPv4, 0);
    _udp = udp;
    // 74-byte discovery packet: type(0x1,2B) + length(0x46,2B) + ssrc(4B)
    // + address(64B) + port(2B).
    final packet = <int>[
      0x00, 0x01, 0x00, 0x46,
      ..._ssrcBytes(),
      ...List<int>.filled(66, 0),
    ];
    final reply = Completer<Datagram>();
    late StreamSubscription<Datagram> sub;
    sub = udp.stream.listen((d) {
      if (!reply.isCompleted) reply.complete(d);
    });
    try {
      await udp.send(packet, address, port);
      final datagram = await reply.future.timeout(config.timeout);
      final data = datagram.data;
      if (data == null || data.length < 74) {
        throw StateError('Balasan IP discovery UDP tidak valid');
      }
      var ipEnd = 8;
      while (ipEnd < 72 && data[ipEnd] != 0) {
        ipEnd++;
      }
      final addrBytes = data.sublist(8, ipEnd);
      final String discoveredIp;
      if (addrBytes.length == 4) {
        discoveredIp = addrBytes.join('.');
      } else if (addrBytes.length == 16) {
        discoveredIp = InternetAddress.fromRawAddress(
          Uint8List.fromList(addrBytes),
          type: InternetAddressType.IPv6,
        ).address;
      } else {
        throw StateError('Panjang alamat IP discovery tidak valid');
      }
      final portBytes = data.sublist(data.length - 2);
      final discoveredPort = (portBytes[0] << 8) | portBytes[1];
      _externalIp = discoveredIp;
      _externalPort = discoveredPort;
      return VoiceUdpDiscovery(ip: discoveredIp, port: discoveredPort);
    } finally {
      await sub.cancel();
    }
  }

  List<int> _ssrcBytes() {
    final s = _ssrc ?? 0;
    return [s & 0xff, (s >> 8) & 0xff, (s >> 16) & 0xff, (s >> 24) & 0xff];
  }

  void _selectProtocol(VoiceUdpDiscovery discovery) {
    _ws?.add(jsonEncode({
      'op': 4,
      'd': {
        'protocol': 'udp',
        'data': {
          'address': discovery.ip,
          'port': discovery.port,
          'mode': config.encryptor.mode,
        },
      },
    }));
  }

  /// Sends an op 5 Speaking update.
  void setSpeaking({required bool speaking, int delay = 0}) {
    _ws?.add(jsonEncode({
      'op': 5,
      'd': {
        'speaking': speaking ? 1 : 0,
        'delay': delay,
        'ssrc': _ssrc ?? 0,
      },
    }));
  }

  /// Sends one RTP-encrypted opus frame through the UDP transport.
  ///
  /// [packet] must be a complete RTP packet (12-byte header + payload);
  /// [sequence] and [timestamp] are used to fill the header.
  Future<void> sendOpusFrame(
    List<int> opusFrame, {
    required int sequence,
    required int timestamp,
  }) async {
    final udp = _udp;
    if (udp == null) throw StateError('UDP voice belum siap');
    final header = <int>[
      0x80,
      0x78,
      (sequence >> 8) & 0xff,
      sequence & 0xff,
      (timestamp >> 24) & 0xff,
      (timestamp >> 16) & 0xff,
      (timestamp >> 8) & 0xff,
      timestamp & 0xff,
      ..._ssrcBytes(),
    ];
    final nonce = List<int>.filled(12, 0)
      ..[0] = 0x80
      ..[1] = 0x78
      ..[2] = (sequence >> 8) & 0xff
      ..[3] = sequence & 0xff
      ..[4] = (timestamp >> 24) & 0xff
      ..[5] = (timestamp >> 16) & 0xff
      ..[6] = (timestamp >> 8) & 0xff
      ..[7] = timestamp & 0xff
      ..setRange(8, 12, _ssrcBytes());
    final encrypted = config.encryptor.encrypt(
      [...header, ...opusFrame],
      nonce,
    );
    await udp.send(
      encrypted,
      InternetAddress.tryParse(_externalIp ?? '') ?? InternetAddress.anyIPv4,
      _externalPort ?? 0,
    );
  }

  /// Leaves the voice channel and tears everything down.
  Future<void> leave() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    try {
      await _udp?.close();
    } catch (_) {}
    _udp = null;
    _running = false;
  }
}

/// Orchestrates a voice conversation loop on a Discord voice channel:
/// STT turns inbound opus frames into text, the handler produces a reply, and
/// TTS renders it back into opus frames.
class DiscordVoiceLoop {
  DiscordVoiceLoop({
    required this.client,
    this.onTranscript,
    this.stt,
    this.tts,
  });

  final DiscordVoiceClient client;

  /// Called with the transcribed text of each utterance.
  final Future<void> Function(String text)? onTranscript;

  /// Speech-to-text hook over raw opus frame payloads.
  final Future<String> Function(List<int> opusFrames)? stt;

  /// Text-to-speech hook returning opus frames to transmit.
  final Future<List<int>> Function(String text)? tts;

  /// Processes one utterance end-to-end and transmits the reply.
  Future<void> handleUtterance(List<int> opusFrames) async {
    final sttFn = stt;
    final text = sttFn == null ? '' : await sttFn(opusFrames);
    if (text.isEmpty) return;
    await onTranscript?.call(text);
    final ttsFn = tts;
    if (ttsFn == null) return;
    final audio = await ttsFn(text);
    client.setSpeaking(speaking: true);
    const frameSize = 512;
    var sequence = 0;
    var timestamp = 0;
    for (var i = 0; i < audio.length; i += frameSize) {
      final end = (i + frameSize < audio.length) ? i + frameSize : audio.length;
      await client.sendOpusFrame(
        audio.sublist(i, end),
        sequence: sequence & 0xffff,
        timestamp: timestamp,
      );
      sequence++;
      timestamp += 960;
    }
    client.setSpeaking(speaking: false);
  }
}
