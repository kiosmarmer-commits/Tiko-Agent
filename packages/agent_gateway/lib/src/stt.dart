import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Speech-to-text providers with fallback chain.
/// Supports: local whisper, local_command, OpenAI, Groq, Gemini, Mistral, xAI,
/// ElevenLabs, DeepInfra
class SttClient {
  SttClient({
    this.whisperBin,
    this.localCommand,
    this.openaiApiKey,
    this.openaiBaseUrl = 'https://api.openai.com/v1',
    this.groqApiKey,
    this.groqBaseUrl = 'https://api.groq.com/v1',
    this.geminiApiKey,
    this.geminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.geminiModel = 'gemini-2.0-flash',
    this.mistralApiKey,
    this.mistralBaseUrl = 'https://api.mistral.ai/v1',
    this.xaiApiKey,
    this.xaiBaseUrl = 'https://api.x.ai/v1',
    this.elevenlabsApiKey,
    this.elevenlabsBaseUrl = 'https://api.elevenlabs.io/v1',
    this.deepinfraApiKey,
    this.deepinfraBaseUrl = 'https://api.deepinfra.com/v1',
    this.minimaxApiKey,
    this.minimaxBaseUrl = 'https://api.minimax.io/v1',
    this.model = 'whisper-1',
    this.providerOrder = const [
      'local',
      'local_command',
      'groq',
      'openai',
      'gemini',
      'mistral',
      'xai',
      'elevenlabs',
      'deepinfra',
      'minimax',
    ],
    http.Client? httpClient,
  }) : _http = httpClient;

  final String? whisperBin;
  final String? localCommand;

  // OpenAI
  final String? openaiApiKey;
  final String openaiBaseUrl;

  // Groq
  final String? groqApiKey;
  final String groqBaseUrl;

  // Gemini (generateContent + inline_data, bukan jalur OpenAI-compat)
  final String? geminiApiKey;
  final String geminiBaseUrl;
  final String geminiModel;

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

  // MiniMax (asr-1.0 — POST /v1/speech_to_text, bukan jalur OpenAI-compat)
  final String? minimaxApiKey;
  final String minimaxBaseUrl;

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
        case 'local_command':
          if (localCommand != null && localCommand!.isNotEmpty) {
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
        case 'gemini':
          if ((geminiApiKey ?? '').isNotEmpty) {
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
        case 'minimax':
          if ((minimaxApiKey ?? '').isNotEmpty) {
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
      case 'local_command':
        return _transcribeLocalCommand(path);
      case 'openai':
        return _transcribeOpenAI(client, path);
      case 'groq':
        return _transcribeGroq(client, path);
      case 'gemini':
        return _transcribeGemini(client, path);
      case 'mistral':
        return _transcribeMistral(client, path);
      case 'xai':
        return _transcribeXAI(client, path);
      case 'elevenlabs':
        return _transcribeElevenLabs(client, path);
      case 'deepinfra':
        return _transcribeDeepInfra(client, path);
      case 'minimax':
        return _transcribeMiniMax(client, path);
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

  Future<String?> _transcribeLocalCommand(String path) async {
    try {
      // Parse the command to extract executable and arguments
      // Format: "executable arg1 arg2 {file}"
      // {file} will be replaced with the actual file path
      final commandParts = localCommand!.split(' ');
      final executable = commandParts[0];
      final args = commandParts.sublist(1);
      
      // Replace {file} placeholder with actual path
      final resolvedArgs = args.map((arg) => arg.replaceAll('{file}', path)).toList();
      
      final r = await Process.run(executable, [
        ...resolvedArgs,
        path,
      ]).timeout(const Duration(seconds: 120));
      
      if (r.exitCode == 0) {
        // Try to get output from stdout
        final stdout = (r.stdout as String).trim();
        if (stdout.isNotEmpty) return stdout;
        
        // Try to read from a file with .txt extension
        final out = File('$path.txt');
        if (await out.exists()) return (await out.readAsString()).trim();
        
        return stdout;
      }
    } catch (e) {
      stderr.writeln('stt: local_command gagal: $e');
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

  Future<String?> _transcribeGemini(
    http.Client client,
    String path,
  ) async {
    try {
      final uri = Uri.parse(
          '$geminiBaseUrl/models/$geminiModel:generateContent');
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) return null;
      final mime = _audioMimeType(path);
      final res = await client
          .post(
            uri,
            headers: {
              'x-goog-api-key': geminiApiKey!,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {
                      'text': 'Transcribe the audio exactly as spoken. '
                          'Return only the transcript text without any '
                          'comment.',
                    },
                    {
                      'inline_data': {
                        'mime_type': mime,
                        'data': base64Encode(bytes),
                      },
                    },
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 120));
      if (res.statusCode >= 400) {
        stderr.writeln('stt: gemini HTTP ${res.statusCode}: ${res.body}');
        return null;
      }
      final json = jsonDecode(res.body);
      if (json is! Map) return null;
      final candidates = json['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;
      final first = candidates.first;
      if (first is! Map) return null;
      final content = first['content'];
      if (content is! Map) return null;
      final parts = content['parts'];
      if (parts is! List || parts.isEmpty) return null;
      final text = parts
          .whereType<Map>()
          .map((part) => part['text']?.toString() ?? '')
          .join()
          .trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      stderr.writeln('stt: gemini error: $e');
      return null;
    }
  }

  String _audioMimeType(String path) {
    switch (path.split('.').last.toLowerCase()) {
      case 'mp3':
        return 'audio/mp3';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'webm':
        return 'audio/webm';
      case 'flac':
        return 'audio/flac';
      case 'aiff':
        return 'audio/aiff';
      default:
        return 'application/octet-stream';
    }
  }

  Future<String?> _transcribeMiniMax(
    http.Client client,
    String path,
  ) async {
    try {
      final uri = Uri.parse('$minimaxBaseUrl/speech_to_text');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${minimaxApiKey!}'
        ..fields['model'] = 'asr-1.0'
        ..fields['response_format'] = 'json'
        ..fields['stream'] = 'false'
        ..files.add(await http.MultipartFile.fromPath('file', path));
      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode >= 400) {
        stderr.writeln('stt: minimax HTTP ${streamed.statusCode}: $body');
        return null;
      }
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final text =
          json['text'] ?? ((json['data'] as Map?)?['text'] as Object?);
      return text?.toString().trim();
    } catch (e) {
      stderr.writeln('stt: minimax error: $e');
      return null;
    }
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
