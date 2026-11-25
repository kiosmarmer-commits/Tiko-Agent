import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../hotword.dart';
import '../subprocess_hotword.dart';

/// Configuration for wake word detection.
class WakeWordConfig {
  const WakeWordConfig({
    this.wakeWord = 'hey tiko',
    this.sensitivity = 0.5,
    this.sampleRate = 16000,
    this.frameLength = 512,
    this.threshold = 0.8,
    this.minDuration = const Duration(milliseconds: 100),
    this.maxSilence = const Duration(milliseconds: 500),
  });

  final String wakeWord;
  final double sensitivity;
  final int sampleRate;
  final int frameLength;
  final double threshold;
  final Duration minDuration;
  final Duration maxSilence;
}

/// Platform-specific wake word detector implementations.
///
/// This provides a unified interface for different wake word detection
/// libraries (Porcupine, openWakeWord, TensorFlow Lite, etc.)
abstract class WakeWordDetector {
  /// Starts the detector.
  Future<void> start();

  /// Stops the detector.
  Future<void> stop();

  /// Processes audio data and returns true if wake word is detected.
  bool processAudio(Uint8List audioData);

  /// Gets the current state of the detector.
  bool get isListening;

  /// Sets the callback for when wake word is detected.
  void setOnDetected(void Function() callback);
}

/// Processes one PCM frame using an optional platform/native wake-word engine.
/// The callback returns `true` only when the configured wake word is detected.
typedef WakeWordFrameProcessor = bool Function(Uint8List audioData);

/// Porcupine-based wake word detector.
///
/// Porcupine is a highly-accurate and lightweight wake word detection engine.
/// This implementation assumes Porcupine is available as a platform library.
class PorcupineWakeWordDetector implements WakeWordDetector {
  PorcupineWakeWordDetector({
    required this.wakeWordPath,
    this.sensitivity = 0.5,
    this.sampleRate = 16000,
    this.nativeProcessor,
  });

  final String wakeWordPath;
  final double sensitivity;
  final int sampleRate;
  final WakeWordFrameProcessor? nativeProcessor;

  bool _isListening = false;
  void Function()? _onDetected;

  @override
  bool get isListening => _isListening;

  @override
  Future<void> start() async {
    if (_isListening) return;

    // A native binding can be supplied through [nativeProcessor].
    _isListening = true;
  }

  @override
  Future<void> stop() async {
    if (!_isListening) return;

    _isListening = false;
    _onDetected = null;
  }

  @override
  bool processAudio(Uint8List audioData) {
    if (!_isListening) return false;

    final nativeDetected = nativeProcessor?.call(audioData) ?? false;
    if (nativeDetected) {
      _onDetected?.call();
      return true;
    }
    if (nativeProcessor != null) return false;
    return _simpleEnergyDetection(audioData);
  }

  @override
  void setOnDetected(void Function() callback) {
    _onDetected = callback;
  }

  /// Simple energy-based fallback used when no native processor is supplied.
  bool _simpleEnergyDetection(Uint8List audioData) {
    // Calculate RMS energy
    double sum = 0;
    for (final sample in audioData) {
      sum += sample * sample;
    }
    final rms = math.sqrt(sum / audioData.length);

    if (rms > 50) {
      _onDetected?.call();
      return true;
    }
    return false;
  }
}

/// openWakeWord-based wake word detector.
///
/// openWakeWord is a lightweight wake word detection system that can be
/// trained on custom wake words.
class OpenWakeWordDetector implements WakeWordDetector {
  OpenWakeWordDetector({
    required this.modelPath,
    this.wakeWord = 'hey tiko',
    this.sensitivity = 0.5,
    this.sampleRate = 16000,
    this.nativeProcessor,
  });

  final String modelPath;
  final String wakeWord;
  final double sensitivity;
  final int sampleRate;
  final WakeWordFrameProcessor? nativeProcessor;

  bool _isListening = false;
  void Function()? _onDetected;

  @override
  bool get isListening => _isListening;

  @override
  Future<void> start() async {
    if (_isListening) return;

    _isListening = true;
  }

  @override
  Future<void> stop() async {
    if (!_isListening) return;

    _isListening = false;
    _onDetected = null;
  }

  @override
  bool processAudio(Uint8List audioData) {
    if (!_isListening) return false;

    final nativeDetected = nativeProcessor?.call(audioData) ?? false;
    if (nativeDetected) {
      _onDetected?.call();
      return true;
    }
    if (nativeProcessor != null) return false;
    double sum = 0;
    for (final sample in audioData) {
      sum += sample * sample;
    }
    final rms = math.sqrt(sum / audioData.length);

    if (rms > 50) {
      _onDetected?.call();
      return true;
    }
    return false;
  }

  @override
  void setOnDetected(void Function() callback) {
    _onDetected = callback;
  }
}

/// Software-based wake word detector using keyword spotting.
///
/// This is a simple keyword spotting implementation that can work without
/// native libraries. It uses basic audio processing to detect the wake word.
class KeywordSpotter implements WakeWordDetector {
  KeywordSpotter({
    this.wakeWord = 'hey tiko',
    this.sampleRate = 16000,
    this.threshold = 0.8,
  });

  final String wakeWord;
  final int sampleRate;
  final double threshold;

  bool _isListening = false;
  void Function()? _onDetected;
  final List<double> _audioBuffer = [];
  static const int _bufferSize = 16000; // 1 second at 16kHz

  @override
  bool get isListening => _isListening;

  @override
  Future<void> start() async {
    if (_isListening) return;
    _isListening = true;
    _audioBuffer.clear();
  }

  @override
  Future<void> stop() async {
    if (!_isListening) return;
    _isListening = false;
    _onDetected = null;
    _audioBuffer.clear();
  }

  @override
  bool processAudio(Uint8List audioData) {
    if (!_isListening) return false;

    // Convert audio data to samples (assuming 16-bit PCM)
    // This is a simplified implementation
    final samples = _convertToSamples(audioData);
    _audioBuffer.addAll(samples);

    // Keep buffer at reasonable size
    if (_audioBuffer.length > _bufferSize) {
      _audioBuffer.removeRange(0, _audioBuffer.length - _bufferSize);
    }

    // The software fallback uses buffered energy; native implementations can
    // be supplied through PorcupineWakeWordDetector/OpenWakeWordDetector.
    if (_audioBuffer.length >= sampleRate) {
      // Simple detection based on energy
      final energy = _calculateEnergy(_audioBuffer);
      if (energy > threshold) {
        _onDetected?.call();
        return true;
      }
    }

    return false;
  }

  @override
  void setOnDetected(void Function() callback) {
    _onDetected = callback;
  }

  List<double> _convertToSamples(Uint8List audioData) {
    // Convert bytes to samples
    // This is a simplified implementation
    final samples = <double>[];
    for (var i = 0; i < audioData.length; i += 2) {
      if (i + 1 < audioData.length) {
        // Read 16-bit little-endian sample
        final sample = audioData[i] | (audioData[i + 1] << 8);
        samples.add(sample / 32768.0); // Normalize to [-1, 1]
      }
    }
    return samples;
  }

  double _calculateEnergy(List<double> samples) {
    double sum = 0;
    for (final sample in samples) {
      sum += sample * sample;
    }
    return math.sqrt(sum / samples.length);
  }
}

/// Hotword listener that uses wake word detection.
///
/// This implementation wraps a wake word detector and provides the
/// HotwordListener interface for use with VoiceLoop.
class WakeWordHotwordListener implements HotwordListener {
  WakeWordHotwordListener({required this.detector, this.label = 'wake_word'});

  final WakeWordDetector detector;
  final String label;

  void Function()? _onDetected;
  bool _isRunning = false;

  @override
  String get name => label;

  @override
  bool get isListening => _isRunning && detector.isListening;

  @override
  Future<void> start(void Function() onDetected) async {
    if (_isRunning) return;

    _onDetected = onDetected;
    detector.setOnDetected(_handleDetection);

    await detector.start();
    _isRunning = true;
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    await detector.stop();
    _onDetected = null;
    _isRunning = false;
  }

  void _handleDetection() {
    if (_isRunning) {
      _onDetected?.call();
    }
  }
}

/// Factory for creating wake word detectors based on platform and configuration.
class WakeWordDetectorFactory {
  static HotwordListener create({
    String? porcupinePath,
    String? openWakeWordPath,
    String wakeWord = 'hey tiko',
    bool usePorcupine = true,
    bool useOpenWakeWord = false,
    List<String>? subprocessCommand,
  }) {
    // Detektor proses eksternal lebih dulu: deteksinya nyata dari engine
    // host (bukan fallback energi-naive).
    if (subprocessCommand != null && subprocessCommand.isNotEmpty) {
      return SubprocessHotwordListener(command: subprocessCommand);
    }

    // Try Porcupine first if available
    if (usePorcupine && porcupinePath != null) {
      try {
        final detector = PorcupineWakeWordDetector(
          wakeWordPath: porcupinePath,
          sensitivity: 0.5,
        );
        return WakeWordHotwordListener(detector: detector);
      } catch (e) {
        // Fall through to next option
      }
    }

    // Try openWakeWord
    if (useOpenWakeWord && openWakeWordPath != null) {
      try {
        final detector = OpenWakeWordDetector(
          modelPath: openWakeWordPath,
          wakeWord: wakeWord,
        );
        return WakeWordHotwordListener(detector: detector);
      } catch (e) {
        // Fall through to keyword spotter
      }
    }

    // Fallback to keyword spotter
    final detector = KeywordSpotter(wakeWord: wakeWord);
    return WakeWordHotwordListener(
      detector: detector,
      label: 'keyword_spotter',
    );
  }
}
