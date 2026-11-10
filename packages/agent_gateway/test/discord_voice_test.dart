import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
        ...buffer.sublist(0, 4),
        ...ip,
        ...List<int>.filled(64 - ip.length, 0),
        0x13, 0x88,
      ];
      controller.add(Datagram(reply, InternetAddress.loopbackIPv4, port));
    }
    return buffer.length;
  }

  @override
  Stream<Datagram> get stream => controller.stream;

  @override
  Future<void> close() async => controller.close();
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
      onTranscript: (_) {},
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

  test('UnsupportedVoiceEncryptor reports its mode and throws on encrypt',
      () async {
    const enc = UnsupportedVoiceEncryptor();
    expect(enc.mode, 'xsalsa20_poly1305');
    expect(() => enc.encrypt([1, 2, 3], List<int>.filled(12, 0)),
        throwsA(isA<UnsupportedError>()));
  });
}
