import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Speech-to-text providers with fallback chain.
/// Supports: local whisper, OpenAI, Groq, Mistral, xAI, ElevenLabs, DeepInfra
class SttClient {
  SttClient({
    this.whisperBin,
    this.openaiApiKey,
    this.openaiBaseUrl = 'https://api.openai.com/v1',
    this.groqApiKey,
    this.groqBaseUrl = 'https://api.groq.com/v1',
    this.mistralApiKey,
    this.mistralBaseUrl = 'https://api.mistral.ai/v1',
    this.xaiApiKey,
    this.xaiBaseUrl = 'https://api.x.ai/v1',
    this.elevenlabsApiKey,
    this.elevenlabsBaseUrl = 'https://api.elevenlabs.io/v1',
    this.deepinfraApiKey,
    this.deepinfraBaseUrl = 'https://api.deepinfra.com/v1',
    this.model = 'whisper-1',
    this.providerOrder = const [
      'local',
      'groq',
      'openai',
      'mistral',
      'xai',
      'elevenlabs',
      'deepinfra',
    ],
    http.Client? httpClient,
  }) : _http = httpClient;

  final String? whisperBin;

  // OpenAI
  final String? openaiApiKey;
  final String openaiBaseUrl;

  // Groq
  final String? groqApiKey;
  final String groqBaseUrl;

  // Mistral
  final String? mistralApiKey;
  final String mistralBaseUrl;

  // xAI
  final String? xaiApiKey;
  final String xaiBaseUrl;

  // ElevenLabs
  final String? elevenlabsApiKey;
  final String elevenlabsBaseUrl;

  // DeepInfra
  final String? deepinfraApiKey;
  final String deepinfraBaseUrl;

  final String model;

  /// Urutan pencobaan provider (fallback chain)
  final List<String> providerOrder;

  final http.Client? _http;

  Future<String?> transcribeFile(String path) async {
    final client = _http ?? http.Client();
    
    // Build list of active providers
    final activeProviders = <String>[];
    for (final providerId in providerOrder) {
      switch (providerId) {
        case 'local':
          if (whisperBin != null && whisperBin!.isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'openai':
          if ((openaiApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'groq':
          if ((groqApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'mistral':
          if ((mistralApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'xai':
          if ((xaiApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'elevenlabs':
          if ((elevenlabsApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
        case 'deepinfra':
          if ((deepinfraApiKey ?? '').isNotEmpty) {
            activeProviders.add(providerId);
          }
          break;
      }
    }

    if (activeProviders.isEmpty) {
      stderr.writeln('stt: Tidak ada provider STT yang aktif');
      return null;
    }

    String? lastError;
    for (final providerId in activeProviders) {
      try {
        final result = await _transcribeWithProvider(client, path, providerId);
        if (result != null) {
          return result;
        }
      } catch (e) {
        lastError = '[$providerId] $e';
        stderr.writeln('stt: $lastError');
        continue;
      }
    }

    stderr.writeln('stt: Semua provider gagal: $lastError');
    return null;
  }

  Future<String?> _transcribeWithProvider(
    http.Client client,
    String path,
    String providerId,
  ) async {
    switch (providerId) {
      case 'local':
        return _transcribeLocal(path);
      case 'openai':
        return _transcribeOpenAI(client, path);
      case 'groq':
        return _transcribeGroq(client, path);
      case 'mistral':
        return _transcribeMistral(client, path);
      case 'xai':
        return _transcribeXAI(client, path);
      case 'elevenlabs':
        return _transcribeElevenLabs(client, path);
      case 'deepinfra':
        return _transcribeDeepInfra(client, path);
      default:
        throw Exception('Provider STT $providerId tidak dikenal');
    }
  }

  Future<String?> _transcribeLocal(String path) async {
    try {
      final r = await Process.run(whisperBin!, [
        path,
        '--output',
        'txt',
      ]).timeout(const Duration(seconds: 120));
      if (r.exitCode == 0) {
        final out = File('$path.txt');
        if (await out.exists()) return (await out.readAsString()).trim();
        return (r.stdout as String).trim();
      }
    } catch (e) {
      stderr.writeln('stt: whisper lokal gagal: $e');
    }
    return null;
  }

  Future<String?> _transcribeOpenAI(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$openaiBaseUrl/audio/transcriptions',
      openaiApiKey!,
      model,
    );
  }

  Future<String?> _transcribeGroq(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$groqBaseUrl/audio/transcriptions',
      groqApiKey!,
      model,
    );
  }

  Future<String?> _transcribeMistral(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$mistralBaseUrl/audio/transcriptions',
      mistralApiKey!,
      model,
    );
  }

  Future<String?> _transcribeXAI(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$xaiBaseUrl/audio/transcriptions',
      xaiApiKey!,
      model,
    );
  }

  Future<String?> _transcribeElevenLabs(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$elevenlabsBaseUrl/audio/transcriptions',
      elevenlabsApiKey!,
      model,
    );
  }

  Future<String?> _transcribeDeepInfra(http.Client client, String path) async {
    return _transcribeGeneric(
      client,
      path,
      '$deepinfraBaseUrl/audio/transcriptions',
      deepinfraApiKey!,
      model,
    );
  }

  Future<String?> _transcribeGeneric(
    http.Client client,
    String path,
    String url,
    String apiKey,
    String model,
  ) async {
    try {
      final uri = Uri.parse(url);
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..fields['model'] = model
        ..files.add(await http.MultipartFile.fromPath('file', path));
      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode >= 400) {
        stderr.writeln('stt: HTTP ${streamed.statusCode}: $body');
        return null;
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['text'] as String?)?.trim();
    } catch (e) {
      stderr.writeln('stt: API error: $e');
      return null;
    }
  }
}
