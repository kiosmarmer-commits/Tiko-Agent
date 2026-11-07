import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

class _FakeTranscriber implements VoiceTranscriber {
  _FakeTranscriber(this._text);

  final String? _text;
  int calls = 0;

  @override
  Future<String?> transcribeFile(String path) async {
    calls++;
    return _text;
  }
}

class _FakeTts implements TtsProvider {
  final List<String> spoken = [];

  @override
  String get id => 'fake-tts';

  @override
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  }) async {
    spoken.add(text);
    return utf8.encode(text);
  }
}

class _FakeHotword implements HotwordListener {
  bool listening = false;
  void Function()? onDetected;

  @override
  String get name => 'fake-hotword';

  @override
  bool get isListening => listening;

  @override
  Future<void> start(void Function() onDetected) async {
    listening = true;
    this.onDetected = onDetected;
  }

  @override
  Future<void> stop() async {
    listening = false;
    onDetected = null;
  }
}

void main() {
  test('satu putaran voice: audio -> stt -> agent -> tts -> playback',
      () async {
    final tts = _FakeTts();
    final played = <List<int>>[];
    final seen = <InboundMessage>[];
    final loop = VoiceLoop(
      transcriber: _FakeTranscriber('halo tiko'),
      tts: tts,
      onMessage: (m) async {
        seen.add(m);
        return 'halo juga!';
      },
      captureAudio: () async => '/tmp/turn1.wav',
      playAudio: (bytes) async => played.add(bytes),
    );

    final result = await loop.runOnce();

    expect(result.transcript, 'halo tiko');
    expect(result.reply, 'halo juga!');
    expect(result.error, isNull);
    expect(seen.single.channel, 'voice');
    expect(seen.single.userKey, 'voice-user');
    expect(seen.single.sessionKey, 'voice-session');
    expect(tts.spoken.single, 'halo juga!');
    expect(played.single, utf8.encode('halo juga!'));
  });

  test('transkripsi kosong: fallback diucapkan dan error dilaporkan',
      () async {
    final tts = _FakeTts();
    final seen = <InboundMessage>[];
    final loop = VoiceLoop(
      transcriber: _FakeTranscriber('   '),
      tts: tts,
      onMessage: (m) async {
        seen.add(m);
        return 'tidak akan terjadi';
      },
      captureAudio: () async => '/tmp/turn2.wav',
      playAudio: (bytes) async {},
    );

    final result = await loop.runOnce();

    expect(result.error, 'transkripsi kosong');
    expect(result.audioPlayed, isTrue);
    expect(tts.spoken.single, contains('Maaf'));
    expect(seen, isEmpty);
  });

  test('run() menjalankan satu putaran per tick wake-up', () async {
    final controller = StreamController<void>();
    var turns = 0;
    final loop = VoiceLoop(
      transcriber: _FakeTranscriber('putaran'),
      tts: _FakeTts(),
      onMessage: (m) async {
        turns++;
        return 'oke';
      },
      captureAudio: () async => '/tmp/tick.wav',
      playAudio: (bytes) async {},
    );

    final done = loop.run(controller.stream);
    controller.add(null);
    controller.add(null);
    await controller.close();
    await done;

    expect(turns, 2);
  });

  test('wakeups() menjembatani hotword dan berhenti saat dibatalkan',
      () async {
    final hotword = _FakeHotword();
    final stream = await VoiceLoop.wakeups(hotword);
    final ticks = <int>[];
    final sub = stream.listen((_) => ticks.add(1));

    hotword.onDetected!();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ticks, hasLength(1));

    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(hotword.listening, isFalse);
  });
}
