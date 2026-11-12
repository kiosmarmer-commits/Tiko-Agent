import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

class FakeVoiceSocket implements VoiceSocket {
  FakeVoiceSocket() {
    scheduleMicrotask(() {
      controller.add(jsonEncode({
        'op': 10,
        'd': {'heartbeat_interval': 41250, 'v': 4},
      }));
    });
  }

  final controller = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];

  @override
  void add(Object data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    sent.add(msg);
    final op = msg['op'];
    if (op == 0) {
      controller.add(jsonEncode({
        'op': 2,
        'd': {
          'ssrc': 12345,
          'ip': '127.0.0.1',
          'port': 50000,
          'modes': ['xsalsa20_poly1305'],
        },
      }));
    } else if (op == 4) {
      controller.add(jsonEncode({
        'op': 6,
        'd': {
          'mode': 'xsalsa20_poly1305',
          'secret_key': List<int>.filled(32, 7),
        },
      }));
    }
  }

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  Future<void> close() async => controller.close();
}

class FakeUdp implements VoiceUdpSocket {
  final controller = StreamController<Datagram>();
  final sent = <(List<int>, InternetAddress, int)>[];

  @override
  Future<int> send(List<int> buffer, InternetAddress address, int port) async {
    sent.add((buffer, address, port));
    if (buffer.length == 74) {
      final ip = ascii.encode('10.0.0.9');
      final reply = <int>[
        ...buffer.sublist(0, 8),
        ...ip,
        ...List<int>.filled(64 - ip.length, 0),
        0x13, 0x88,
      ];
      controller.add(
        Datagram(Uint8List.fromList(reply), InternetAddress.loopbackIPv4, port),
      );
    }
    return buffer.length;
  }

  @override
  Stream<Datagram> get stream => controller.stream;

  @override
  Future<void> close() async => controller.close();
}

class _PassthroughEncryptor implements VoiceEncryptor {
  const _PassthroughEncryptor();

  @override
  String get mode => 'xsalsa20_poly1305';

  @override
  List<int> encrypt(List<int> payload, List<int> nonce, List<int> secretKey) =>
      payload;
}

void main() {
  late HttpServer api;
  late Uri apiBase;
  late FakeVoiceSocket ws;
  late FakeUdp udp;

  setUp(() async {
    api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    apiBase = Uri.parse('http://127.0.0.1:${api.port}');
    api.listen((req) async {
      expect(req.method, 'PATCH');
      expect(req.uri.path, contains('/voice-states/@me'));
      req.response.statusCode = 200;
      req.response.write('{}');
      await req.response.close();
    });
    ws = FakeVoiceSocket();
    udp = FakeUdp();
  });

  tearDown(() async {
    await api.close(force: true);
  });

  DiscordVoiceClient buildClient() {
    return DiscordVoiceClient(
      config: DiscordVoiceConfig(
        botToken: 'tok',
        guildId: 'g1',
        channelId: 'c1',
        apiBaseUrl: apiBase.toString(),
        wsFactory: (_) async => ws,
        udpFactory: (_, __) async => udp,
        encryptor: const _PassthroughEncryptor(),
      ),
    );
  }

  test('join() completes the full voice handshake', () async {
    final client = buildClient();
    client.handleDispatch('VOICE_STATE_UPDATE', {
      'session_id': 'sess-1',
      'user_id': 'u1',
    });
    client.handleDispatch('VOICE_SERVER_UPDATE', {
      'token': 'voice-tok',
      'endpoint': 'voice.example.invalid:443',
    });

    await client.join();

    expect(client.isReady, isTrue);
    expect(client.ssrc, 12345);

    final identify = ws.sent.firstWhere((m) => m['op'] == 0);
    expect(identify['d']['session_id'], 'sess-1');
    expect(identify['d']['user_id'], 'u1');
    expect(identify['d']['token'], 'voice-tok');
    expect(identify['d']['server_id'], 'g1');

    final select = ws.sent.firstWhere((m) => m['op'] == 4);
    expect(select['d']['protocol'], 'udp');
    expect(select['d']['data']['address'], '10.0.0.9');
    expect(select['d']['data']['port'], 5000);
    expect(select['d']['data']['mode'], 'xsalsa20_poly1305');

    expect(udp.sent.first.$1.length, 74);
    await client.leave();
  });

  test('join() times out when voice dispatches never arrive', () async {
    final client = DiscordVoiceClient(
      config: DiscordVoiceConfig(
        botToken: 'tok',
        guildId: 'g1',
        channelId: 'c1',
        apiBaseUrl: apiBase.toString(),
        timeout: const Duration(milliseconds: 100),
        wsFactory: (_) async => ws,
        udpFactory: (_, __) async => udp,
      ),
    );
    await expectLater(client.join(), throwsA(isA<TimeoutException>()));
  });

  test('sendOpusFrame routes through the encryptor to UDP', () async {
    final client = buildClient();
    client.handleDispatch('VOICE_STATE_UPDATE', {'session_id': 's'});
    client.handleDispatch('VOICE_SERVER_UPDATE', {
      'token': 't',
      'endpoint': 'voice.example.invalid',
    });
    await client.join();

    final loop = DiscordVoiceLoop(
      client: client,
      stt: (_) async => 'halo',
      tts: (text) async => List<int>.filled(700, 9),
      onTranscript: (_) async {},
    );
    await loop.handleUtterance(List<int>.filled(10, 1));

    final frames = udp.sent.where((s) => s.$1.length != 74).toList();
    expect(frames, isNotEmpty);
    final first = frames.first.$1;
    expect(first[0], 0x80);
    expect(first[1], 0x78);
    expect(udp.sent.last.$3, 5000);
    await client.leave();
  });

  test('Xsalsa20Poly1305Encryptor matches libsodium secretbox vectors', () {
    const enc = Xsalsa20Poly1305Encryptor();
    expect(enc.mode, 'xsalsa20_poly1305');

    final key = [for (var i = 0; i < 32; i++) i];
    final nonce = [
      3, 10, 17, 24, 31, 38, 45, 52, 59, 66, 73, 80,
      87, 94, 101, 108, 115, 122, 129, 136, 143, 150, 157, 164,
    ];
    final msg = [
      72, 97, 108, 111, 32, 84, 105, 107, 111, 33, 32, 86, 111, 105, 99, 101,
      32, 101, 110, 99, 114, 121, 112, 116, 105, 111, 110, 32, 116, 101, 115,
      116, 46,
    ];
    final expected = [
      231, 65, 139, 188, 112, 23, 174, 57, 253, 152, 16, 242, 115, 20, 233,
      163, 54, 88, 210, 40, 155, 97, 23, 156, 240, 155, 232, 212, 102, 135,
      118, 149, 53, 15, 14, 170, 81, 192, 71, 225, 63, 242, 178, 88, 145, 91,
      110, 167, 190,
    ];
    expect(enc.encrypt(msg, nonce, key), expected);

    final empty = [
      233, 114, 111, 141, 55, 61, 143, 209, 236, 10, 79, 77, 236, 16, 187, 87,
    ];
    expect(enc.encrypt(const [], nonce, key), empty);
  });

  test('naclSecretbox roundtrip and tamper detection', () {
    final key = List<int>.generate(32, (i) => i * 3 + 1);
    final nonce = List<int>.generate(24, (i) => i * 5 + 2);
    final msg = List<int>.generate(300, (i) => i * 13 + 5);

    final box = naclSecretbox(msg, nonce, key);
    expect(box.length, msg.length + 16);
    expect(naclSecretboxOpen(box, nonce, key), msg);

    final tampered = List<int>.of(box)..[20] ^= 0x01;
    expect(
      () => naclSecretboxOpen(tampered, nonce, key),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('sendOpusFrame seals the payload with the op 6 secret key', () async {
    final client = DiscordVoiceClient(
      config: DiscordVoiceConfig(
        botToken: 'tok',
        guildId: 'g1',
        channelId: 'c1',
        apiBaseUrl: apiBase.toString(),
        wsFactory: (_) async => ws,
        udpFactory: (_, __) async => udp,
        encryptor: const Xsalsa20Poly1305Encryptor(),
      ),
    );
    client.handleDispatch('VOICE_STATE_UPDATE', {'session_id': 's'});
    client.handleDispatch('VOICE_SERVER_UPDATE', {
      'token': 't',
      'endpoint': 'voice.example.invalid',
    });
    await client.join();

    final loop = DiscordVoiceLoop(
      client: client,
      stt: (_) async => 'halo',
      tts: (text) async => List<int>.filled(700, 9),
      onTranscript: (_) async {},
    );
    await loop.handleUtterance(List<int>.filled(10, 1));

    final frames = udp.sent.where((s) => s.$1.length != 74).toList();
    expect(frames, isNotEmpty);
    final first = frames.first.$1;
    expect(first[0], 0x80);
    expect(first[1], 0x78);
    // RTP header (12 bytes) stays in clear, followed by the secretbox.
    final box = first.sublist(12);
    final nonce = [...first.sublist(0, 12), ...List<int>.filled(12, 0)];
    final opened = naclSecretboxOpen(box, nonce, List<int>.filled(32, 7));
    // Loop chunks TTS audio into 512-byte frames; first frame carries 512.
    expect(opened.length, 512);
    expect(opened, List<int>.filled(512, 9));
    await client.leave();
  });
}
