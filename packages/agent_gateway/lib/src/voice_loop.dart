import 'dart:async';

import 'package:agent_core/agent_core.dart';

import 'hotword.dart';
import 'stt.dart';
import 'tts.dart';

/// Seam over [SttClient] so the voice loop can be driven with a fake in
/// tests.
abstract class VoiceTranscriber {
  Future<String?> transcribeFile(String path);
}

/// Adapts [SttClient] to [VoiceTranscriber].
class SttClientTranscriber implements VoiceTranscriber {
  const SttClientTranscriber(this.client);

  final SttClient client;

  @override
  Future<String?> transcribeFile(String path) =>
      client.transcribeFile(path);
}

/// Outcome of one voice turn (for logs, metrics and tests).
class VoiceTurnResult {
  const VoiceTurnResult({
    required this.transcript,
    required this.reply,
    required this.audioPlayed,
    this.error,
  });

  final String transcript;
  final String reply;
  final bool audioPlayed;
  final String? error;
}

/// FR-08 (Real-Time Voice): orchestrates one voice turn -
/// capture audio -> STT -> agent -> TTS -> playback.
///
/// Audio capture and playback stay platform-specific; callers inject
/// them as seams so the loop itself stays pure and testable. The agent
/// seam mirrors the gateway contract: transcript in, reply text out.
class VoiceLoop {
  VoiceLoop({
    required this.transcriber,
    required this.tts,
    required this.onMessage,
    required this.captureAudio,
    required this.playAudio,
    this.userKey = 'voice-user',
    this.sessionKey = 'voice-session',
    this.voice,
    this.model,
  });

  /// Speech-to-text seam.
  final VoiceTranscriber transcriber;

  /// Text-to-speech provider (OpenAI-compatible or ElevenLabs).
  final TtsProvider tts;

  /// The agent seam: receives the transcript, returns the reply text.
  final Future<String> Function(InboundMessage message) onMessage;

  /// Captures one utterance and returns the audio file path.
  final Future<String> Function() captureAudio;

  /// Plays synthesized audio bytes (platform speaker / player).
  final Future<void> Function(List<int> bytes) playAudio;

  final String userKey;
  final String sessionKey;
  final String? voice;
  final String? model;

  /// Runs one full voice turn.
  Future<VoiceTurnResult> runOnce() async {
    final path = await captureAudio();
    final transcript =
        (await transcriber.transcribeFile(path))?.trim() ?? '';
    if (transcript.isEmpty) {
      const fallback = 'Maaf, aku tidak menangkap ucapannya. Coba ya.';
      final bytes = await tts.synthesize(
        fallback,
        voice: voice,
        model: model,
      );
      await playAudio(bytes);
      return const VoiceTurnResult(
        transcript: '',
        reply: fallback,
        audioPlayed: true,
        error: 'transkripsi kosong',
      );
    }
    final reply = await onMessage(
      InboundMessage(
        channel: 'voice',
        userKey: userKey,
        sessionKey: sessionKey,
        text: transcript,
      ),
    );
    final bytes = await tts.synthesize(reply, voice: voice, model: model);
    await playAudio(bytes);
    return VoiceTurnResult(
      transcript: transcript,
      reply: reply,
      audioPlayed: true,
    );
  }

  /// Runs one turn for every wake-up tick; completes when [wakeups]
  /// closes.
  Future<void> run(Stream<void> wakeups) async {
    await for (final _ in wakeups) {
      await runOnce();
    }
  }

  /// Bridges a [HotwordListener] into a wake-up stream for [run]. The
  /// listener is released when the stream subscription is cancelled.
  static Future<Stream<void>> wakeups(HotwordListener listener) async {
    final controller = StreamController<void>.broadcast();
    await listener.start(() => controller.add(null));
    controller.onCancel = () {
      listener.stop();
    };
    return controller.stream;
  }
}
