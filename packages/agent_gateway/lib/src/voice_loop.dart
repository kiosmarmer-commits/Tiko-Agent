import 'dart:async';

import 'package:agent_core/agent_core.dart';

import 'hotword.dart';
import 'stt.dart';
import 'tts.dart';
import 'voice/wake_word_detector.dart';

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
///
/// Supports two modes:
/// - Push-to-talk: Manual trigger for each utterance
/// - Continuous: Always-on with wake word detection for hands-free operation
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
    this.hotwordListener,
    this.continuousListening = false,
    this.wakeWordConfig = const WakeWordConfig(),
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

  /// Hotword listener for wake word detection (optional).
  final HotwordListener? hotwordListener;

  /// Whether to enable continuous listening mode.
  final bool continuousListening;

  /// Configuration for wake word detection.
  final WakeWordConfig wakeWordConfig;

  final String userKey;
  final String sessionKey;
  final String? voice;
  final String? model;
  
  bool _isRunning = false;
  StreamSubscription<void>? _wakeupSubscription;

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

  /// Starts continuous listening mode with wake word detection.
  ///
  /// In this mode, the voice loop listens continuously for the wake word,
  /// then captures and processes the user's utterance automatically.
  /// This provides a hands-free voice experience similar to Hermes Agent.
  Future<void> startContinuousListening() async {
    if (_isRunning) return;
    if (!continuousListening) {
      throw StateError('Continuous listening is not enabled');
    }
    
    _isRunning = true;
    
    // Use provided hotword listener or create a default one
    final listener = hotwordListener ?? 
        WakeWordDetectorFactory.create(
          wakeWord: wakeWordConfig.wakeWord,
        );
    
    // Create wake-up stream from hotword listener
    final wakeups = await VoiceLoop.wakeups(listener);
    
    // Start listening for wake words
    _wakeupSubscription = wakeups.listen((_) async {
      await runOnce();
    });
  }

  /// Stops continuous listening mode.
  Future<void> stopContinuousListening() async {
    if (!_isRunning) return;
    
    await _wakeupSubscription?.cancel();
    _wakeupSubscription = null;
    _isRunning = false;
  }

  /// Runs a continuous voice conversation with automatic turn-taking.
  ///
  /// This method provides a more natural conversation flow where:
  /// 1. User speaks after wake word or push-to-talk
  /// 2. Agent responds with TTS
  /// 3. Agent automatically listens for user's next utterance (no wake word needed)
  /// 4. Conversation continues until user explicitly ends it
  Future<void> runContinuousConversation({
    required Future<bool> Function() shouldContinue,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    while (await shouldContinue()) {
      final result = await runOnce();
      
      // If the agent's response indicates the conversation should end
      if (result.reply.toLowerCase().contains('selesai') ||
          result.reply.toLowerCase().contains('tutup') ||
          result.reply.toLowerCase().contains('berhenti')) {
        break;
      }
      
      // Small delay before listening for next utterance
      await Future.delayed(const Duration(milliseconds: 500));
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

  /// Creates a VoiceLoop with wake word detection enabled.
  ///
  /// This is a convenience factory for creating a voice loop with
  /// continuous listening and wake word detection.
  static VoiceLoop withWakeWord({
    required VoiceTranscriber transcriber,
    required TtsProvider tts,
    required Future<String> Function(InboundMessage message) onMessage,
    required Future<String> Function() captureAudio,
    required Future<void> Function(List<int> bytes) playAudio,
    HotwordListener? hotwordListener,
    String userKey = 'voice-user',
    String sessionKey = 'voice-session',
    String? voice,
    String? model,
    WakeWordConfig wakeWordConfig = const WakeWordConfig(),
  }) {
    return VoiceLoop(
      transcriber: transcriber,
      tts: tts,
      onMessage: onMessage,
      captureAudio: captureAudio,
      playAudio: playAudio,
      userKey: userKey,
      sessionKey: sessionKey,
      voice: voice,
      model: model,
      hotwordListener: hotwordListener,
      continuousListening: true,
      wakeWordConfig: wakeWordConfig,
    );
  }

  /// Checks if the voice loop is currently running in continuous mode.
  bool get isRunning => _isRunning;
}
