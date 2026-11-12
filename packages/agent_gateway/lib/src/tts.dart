import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// FR-08 (Real-Time Voice): text-to-speech clients.
///
/// Two providers out of the box:
/// - [OpenAiTtsProvider]: any OpenAI-compatible endpoint (`POST
///   {baseUrl}/audio/speech`, e.g. OpenAI, Groq, LM Studio, vLLM).
/// - [ElevenLabsTtsProvider]: ElevenLabs REST (`POST /v1/text-to-speech/{voiceId}`).
abstract class TtsProvider {
  String get id;
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  });
}

class OpenAiTtsProvider implements TtsProvider {
  OpenAiTtsProvider({
    required this.apiKey,
    this.id = 'openai-tts',
    this.baseUrl = 'https://api.openai.com/v1',
    this.defaultModel = 'tts-1',
    this.defaultVoice = 'alloy',
    this.client,
  });

  @override
  final String id;

  final String apiKey;
  final String baseUrl;
  final String defaultModel;
  final String defaultVoice;
  final http.Client? client;

  http.Client get _client => client ?? http.Client();


  @override
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('teks kosong');
    if (text.length > 4096) {
      throw ArgumentError('teks terlalu panjang (maks 4096 karakter sekali panggil)');
    }
    final resp = await _client.post(
      Uri.parse('$baseUrl/audio/speech'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model ?? defaultModel,
        'voice': voice ?? defaultVoice,
        'input': text,
        'response_format': 'mp3',
      }),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw StateError(
        'TTS gagal (HTTP ${resp.statusCode}): '
        '${utf8.decode(resp.bodyBytes, allowMalformed: true).substring(0, 200)}',
      );
    }
    return resp.bodyBytes;
  }
}

class ElevenLabsTtsProvider implements TtsProvider {
  ElevenLabsTtsProvider({
    required this.apiKey,
    this.voiceId = '21m00Tcm4TlvDq8ikWAM',
    this.modelId = 'eleven_multilingual_v2',
    this.client,
  });

  final String apiKey;
  final String voiceId;
  final String modelId;
  final http.Client? client;

  http.Client get _client => client ?? http.Client();

  @override
  String get id => 'elevenlabs';

  @override
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('teks kosong');
    final vid = voice ?? voiceId;
    final resp = await _client.post(
      Uri.parse(
        'https://api.elevenlabs.io/v1/text-to-speech/$vid?output_format=mp3_44100_128',
      ),
      headers: {
        'xi-api-key': apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'text': text,
        'model_id': model ?? modelId,
      }),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw StateError(
        'TTS gagal (HTTP ${resp.statusCode}): '
        '${utf8.decode(resp.bodyBytes, allowMalformed: true).substring(0, 200)}',
      );
    }
    return resp.bodyBytes;
  }
}

/// Small façade: synthesizes text and (optionally) writes an audio file.
class TtsService {
  TtsService(this.provider);

  final TtsProvider provider;

  /// Returns raw audio bytes.
  Future<List<int>> speak(String text, {String? voice, String? model}) =>
      provider.synthesize(text, voice: voice, model: model);

  /// Synthesizes and writes to [path]; returns the file path on success.
  Future<String> speakToFile(
    String text,
    String path, {
    String? voice,
    String? model,
  }) async {
    final bytes = await speak(text, voice: voice, model: model);
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }
}
