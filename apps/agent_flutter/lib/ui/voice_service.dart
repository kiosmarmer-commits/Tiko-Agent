import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Abstraksi mesin suara (GUI Voice UI) sehingga seluruh widget dapat diuji
/// dengan fake tanpa menyentuh platform channel di `flutter test`.
abstract interface class VoiceEngine {
  Future<bool> sttAvailable();

  Future<void> startListening({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function() onEnd,
    required void Function(String error) onError,
  });

  Future<void> stopListening();

  Future<void> speak(String text, {void Function()? onDone});

  Future<void> stopSpeaking();
}

class PlatformVoiceEngine implements VoiceEngine {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  void Function()? _onListenEnd;

  Future<bool> _ensureInitialized() async {
    if (!_initialized) {
      _initialized = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _onListenEnd?.call();
          }
        },
      );
    }
    return _initialized;
  }

  @override
  Future<bool> sttAvailable() async {
    if (_initialized) return _speech.isAvailable;
    final ok = await _speech.initialize();
    _initialized = true;
    return ok && _speech.isAvailable;
  }

  @override
  Future<void> startListening({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function() onEnd,
    required void Function(String error) onError,
  }) async {
    if (!await _ensureInitialized()) {
      throw StateError('Pengenalan suara tidak tersedia di perangkat ini');
    }
    _onListenEnd = onEnd;
    await _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords;
        if (result.finalResult) {
          onFinal(text);
        } else {
          onPartial(text);
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(seconds: 30),
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  Future<void> stopListening() async {
    _onListenEnd = null;
    await _speech.stop();
  }

  @override
  Future<void> speak(String text, {void Function()? onDone}) async {
    await _tts.setLanguage('id-ID');
    if (onDone != null) {
      _tts.setCompletionHandler(onDone);
    }
    await _tts.speak(text);
  }

  @override
  Future<void> stopSpeaking() => _tts.stop();
}

/// State machine voice: dikte (STT) + pembacaan balasan (TTS). Satu instance
/// dibagikan dari app shell ke chat page dan composer.
class VoiceService extends ChangeNotifier {
  VoiceService({VoiceEngine? engine})
    : _engine = engine ?? PlatformVoiceEngine();

  final VoiceEngine _engine;

  bool listening = false;
  bool speaking = false;
  String partial = '';

  VoiceEngine get engine => _engine;

  Future<void> toggleListening({
    required void Function(String text) onFinal,
  }) async {
    if (listening) {
      await stopListening();
      return;
    }
    partial = '';
    listening = true;
    notifyListeners();
    try {
      await _engine.startListening(
        onPartial: (text) {
          partial = text;
          notifyListeners();
        },
        onFinal: (text) {
          partial = text;
          onFinal(text);
        },
        onEnd: () {
          if (!listening) return;
          listening = false;
          partial = '';
          notifyListeners();
        },
        onError: (error) {
          listening = false;
          partial = '';
          notifyListeners();
        },
      );
    } catch (error) {
      listening = false;
      partial = '';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopListening() async {
    await _engine.stopListening();
    listening = false;
    partial = '';
    notifyListeners();
  }

  /// Bacakan teks dengan TTS; status `speaking` diakhiri lewat callback
  /// `onDone` dari engine (completion handler).
  Future<void> speak(String text, {void Function()? onDone}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await stopSpeaking();
    speaking = true;
    notifyListeners();
    await _engine.speak(
      clean,
      onDone: () {
        speaking = false;
        notifyListeners();
        onDone?.call();
      },
    );
  }

  Future<void> stopSpeaking() async {
    await _engine.stopSpeaking();
    speaking = false;
    notifyListeners();
  }

  /// Teks balasan assistant terakhir yang layak dibacakan (skip placeholder,
  /// pesan gagal, dan '(selesai)').
  static String? speakableReply(List<Map<String, String>> messages) {
    for (final message in messages.reversed) {
      if (message['role'] != 'assistant') continue;
      final text = (message['text'] ?? '').toString().trim();
      if (text.isEmpty || text == '(selesai)') continue;
      if (text.startsWith('Gagal:')) return null;
      return text;
    }
    return null;
  }
}
