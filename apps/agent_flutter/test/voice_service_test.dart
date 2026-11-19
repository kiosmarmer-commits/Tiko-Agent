import 'package:agent_flutter/ui/settings_store.dart';
import 'package:agent_flutter/ui/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeVoiceEngine implements VoiceEngine {
  final List<String> calls = [];
  void Function(String)? lastPartial;
  void Function(String)? lastFinal;
  void Function()? lastEnd;
  void Function(String)? lastError;
  void Function()? lastSpeakDone;
  bool available = true;
  bool failStart = false;
  List<String> spoken = [];

  @override
  Future<bool> sttAvailable() async {
    calls.add('sttAvailable');
    return available;
  }

  @override
  Future<void> startListening({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function() onEnd,
    required void Function(String error) onError,
  }) async {
    calls.add('start');
    if (failStart) throw StateError('tidak tersedia');
    lastPartial = onPartial;
    lastFinal = onFinal;
    lastEnd = onEnd;
    lastError = onError;
  }

  @override
  Future<void> stopListening() async {
    calls.add('stop');
  }

  @override
  Future<void> speak(String text, {void Function()? onDone}) async {
    calls.add('speak');
    spoken.add(text);
    lastSpeakDone = onDone;
  }

  @override
  Future<void> stopSpeaking() async {
    calls.add('stopSpeak');
  }
}

void main() {
  test(
    'toggleListening: mulai -> state listening, onFinal diteruskan',
    () async {
      final engine = FakeVoiceEngine();
      final voice = VoiceService(engine: engine);
      final finals = <String>[];

      await voice.toggleListening(onFinal: finals.add);
      expect(voice.listening, isTrue);
      expect(voice.partial, isEmpty);
      expect(engine.calls, contains('start'));

      engine.lastPartial!('halo');
      expect(voice.partial, 'halo');

      engine.lastFinal!('halo tiko');
      expect(finals, ['halo tiko']);
    },
  );

  test(
    'toggleListening: onEnd mengakhiri state dan membersihkan partial',
    () async {
      final engine = FakeVoiceEngine();
      final voice = VoiceService(engine: engine);
      await voice.toggleListening(onFinal: (_) {});
      engine.lastPartial!('sep');
      engine.lastEnd!();
      expect(voice.listening, isFalse);
      expect(voice.partial, isEmpty);
    },
  );

  test('toggleListening mundur memanggil stopListening', () async {
    final engine = FakeVoiceEngine();
    final voice = VoiceService(engine: engine);
    await voice.toggleListening(onFinal: (_) {});
    await voice.toggleListening(onFinal: (_) {});
    expect(engine.calls.where((c) => c == 'stop'), hasLength(1));
    expect(voice.listening, isFalse);
  });

  test('gagal startListening melempar dan mereset state', () async {
    final engine = FakeVoiceEngine()..failStart = true;
    final voice = VoiceService(engine: engine);
    await expectLater(voice.toggleListening(onFinal: (_) {}), throwsStateError);
    expect(voice.listening, isFalse);
    expect(voice.partial, isEmpty);
  });

  test('speak: teruskan teks ke engine, onDone mengakhiri speaking', () async {
    final engine = FakeVoiceEngine();
    final voice = VoiceService(engine: engine);
    var done = false;
    await voice.speak('Halo dari Tiko', onDone: () => done = true);
    expect(engine.spoken, ['Halo dari Tiko']);
    expect(voice.speaking, isTrue);
    engine.lastSpeakDone!();
    expect(voice.speaking, isFalse);
    expect(done, isTrue);
  });

  test('speak: teks kosong tidak dikirim ke engine', () async {
    final engine = FakeVoiceEngine();
    final voice = VoiceService(engine: engine);
    await voice.speak('   ');
    expect(engine.calls, isNot(contains('speak')));
  });

  test(
    'speakableReply: balasan assistant terakhir, skip placeholder & gagal',
    () {
      final ok = VoiceService.speakableReply([
        {'role': 'user', 'text': 'hai'},
        {'role': 'assistant', 'text': 'Halo!'},
      ]);
      expect(ok, 'Halo!');

      final placeholder = VoiceService.speakableReply([
        {'role': 'assistant', 'text': '(selesai)'},
      ]);
      expect(placeholder, isNull);

      final failed = VoiceService.speakableReply([
        {'role': 'assistant', 'text': 'Gagal: socket'},
      ]);
      expect(failed, isNull);
    },
  );

  test('AppSettings: voiceReply persist', () async {
    SharedPreferences.setMockInitialValues({});
    final initial = await AppSettings.load();
    expect(initial.voiceReply, isFalse);

    await initial.copyWith(voiceReply: true).save();
    final reloaded = await AppSettings.load();
    expect(reloaded.voiceReply, isTrue);
  });
}
