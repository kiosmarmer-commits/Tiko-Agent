import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'tts.dart';

/// Metadata for one TTS provider in the catalog.
class TtsProviderInfo {
  const TtsProviderInfo({
    required this.id,
    required this.label,
    required this.kind,
    this.requiresApiKey = true,
  });

  final String id;
  final String label;

  /// `http` for REST endpoints, `command` for local CLI engines.
  final String kind;
  final bool requiresApiKey;
}

/// Catalog of supported TTS providers (Hermes Agent parity: 10 providers).
class TtsProviderCatalog {
  const TtsProviderCatalog();

  static const List<TtsProviderInfo> providers = [
    TtsProviderInfo(id: 'edge-tts', label: 'Edge TTS (free)', kind: 'command', requiresApiKey: false),
    TtsProviderInfo(id: 'elevenlabs', label: 'ElevenLabs', kind: 'http'),
    TtsProviderInfo(id: 'openai-tts', label: 'OpenAI TTS', kind: 'http'),
    TtsProviderInfo(id: 'minimax', label: 'MiniMax', kind: 'http'),
    TtsProviderInfo(id: 'mistral-voxtral', label: 'Mistral Voxtral', kind: 'http'),
    TtsProviderInfo(id: 'google-gemini', label: 'Google Gemini TTS', kind: 'http'),
    TtsProviderInfo(id: 'xai', label: 'xAI (Grok voice)', kind: 'http'),
    TtsProviderInfo(id: 'neutts', label: 'NeuTTS (local server)', kind: 'http', requiresApiKey: false),
    TtsProviderInfo(id: 'kittentts', label: 'KittenTTS (local server)', kind: 'http', requiresApiKey: false),
    TtsProviderInfo(id: 'piper', label: 'Piper (local CLI)', kind: 'command', requiresApiKey: false),
  ];

  static const List<String> ids = [
    'edge-tts',
    'elevenlabs',
    'openai-tts',
    'minimax',
    'mistral-voxtral',
    'google-gemini',
    'xai',
    'neutts',
    'kittentts',
    'piper',
  ];

  TtsProviderInfo? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Configuration for the generic HTTP TTS provider.
class HttpTtsProviderConfig {
  const HttpTtsProviderConfig({
    required this.id,
    required this.url,
    this.headers = const {},
    required this.bodyTemplate,
    this.jsonAudioField,
    this.audioEncoding = 'base64',
    this.defaultVoice,
    this.defaultModel,
    this.timeout = const Duration(seconds: 60),
  });

  final String id;
  final String url;
  final Map<String, String> headers;

  /// JSON body template; `{{text}}`, `{{text_json}}`, `{{voice}}`, and
  /// `{{model}}` placeholders are substituted per request.
  final String bodyTemplate;

  /// Dotted JSON path to the audio payload (e.g. `data.audio`). When null the
  /// raw response body bytes are returned.
  final String? jsonAudioField;

  /// `base64` or `hex` decoding for [jsonAudioField] payloads.
  final String audioEncoding;
  final String? defaultVoice;
  final String? defaultModel;
  final Duration timeout;
}

/// Generic template-driven HTTP TTS provider covering MiniMax, Mistral
/// Voxtral, Google Gemini, xAI, NeuTTS, KittenTTS, and any bespoke REST TTS.
class HttpTtsProvider implements TtsProvider {
  HttpTtsProvider({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  final HttpTtsProviderConfig config;
  final http.Client _client;

  @override
  String get id => config.id;

  @override
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('teks kosong');
    final body = config.bodyTemplate
        // Templates may wrap the placeholder in quotes (e.g. jsonEncode'd
        // maps); substitute the quoted form first to avoid double encoding.
        .replaceAll('"{{text_json}}"', jsonEncode(text))
        .replaceAll('{{text_json}}', jsonEncode(text))
        .replaceAll('{{text}}', text)
        .replaceAll('{{voice}}', voice ?? config.defaultVoice ?? '')
        .replaceAll('{{model}}', model ?? config.defaultModel ?? '');
    final res = await _client
        .post(
          Uri.parse(config.url),
          headers: {...config.headers, 'content-type': 'application/json'},
          body: body,
        )
        .timeout(config.timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'TTS ${config.id} gagal: HTTP ${res.statusCode} '
        '${utf8.decode(res.bodyBytes, allowMalformed: true).substring(0, 200)}',
      );
    }
    final field = config.jsonAudioField;
    if (field == null) return res.bodyBytes;
    final payload = _extract(jsonDecode(res.body), field.split('.'));
    final encoded = payload?.toString() ?? '';
    if (encoded.isEmpty) {
      throw StateError('TTS ${config.id} tidak mengembalikan audio');
    }
    return config.audioEncoding == 'hex'
        ? _fromHex(encoded)
        : base64Decode(encoded);
  }

  static dynamic _extract(dynamic node, List<String> path) {
    for (final key in path) {
      final index = int.tryParse(key);
      if (index != null && node is List<dynamic> && index < node.length) {
        node = node[index];
      } else if (node is Map<String, dynamic> && node.containsKey(key)) {
        node = node[key];
      } else {
        return null;
      }
    }
    return node;
  }

  static List<int> _fromHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final out = List<int>.filled(clean.length ~/ 2, 0);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// Local CLI TTS engine (Edge TTS, Piper, or any custom command).
///
/// [commandTemplate] is an argv list whose tokens may contain `{{text}}`,
/// `{{text_json}}`, `{{voice}}`, `{{model}}`, and `{{output}}`. When
/// `{{output}}` is present the produced file is read as the audio; otherwise
/// the command's stdout is used.
class CommandTtsProvider implements TtsProvider {
  CommandTtsProvider({
    required this.id,
    required this.commandTemplate,
    this.defaultVoice,
    this.defaultModel,
    this.timeout = const Duration(seconds: 60),
  });

  final String id;
  final List<String> commandTemplate;
  final String? defaultVoice;
  final String? defaultModel;
  final Duration timeout;

  @override
  Future<List<int>> synthesize(
    String text, {
    String? voice,
    String? model,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('teks kosong');
    final needsFile = commandTemplate.any((t) => t.contains('{{output}}'));
    final outputFile = needsFile
        ? '${Directory.systemTemp.path}/tiko-tts-${DateTime.now().microsecondsSinceEpoch}.audio'
        : null;
    final argv = commandTemplate
        .map((token) => token
            .replaceAll('{{text_json}}', jsonEncode(text))
            .replaceAll('{{text}}', text)
            .replaceAll('{{voice}}', voice ?? defaultVoice ?? '')
            .replaceAll('{{model}}', model ?? defaultModel ?? '')
            .replaceAll('{{output}}', outputFile ?? ''))
        .toList();
    final result = await Process.run(
      argv.first,
      argv.sublist(1),
      stdoutEncoding: null,
      stderrEncoding: utf8,
    ).timeout(timeout);
    if (result.exitCode != 0) {
      throw StateError(
        'TTS $id gagal (exit ${result.exitCode}): ${result.stderr}',
      );
    }
    if (outputFile != null) {
      final file = File(outputFile);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      if (bytes.isEmpty) {
        throw StateError('TTS $id tidak menghasilkan audio');
      }
      return bytes;
    }
    final bytes = result.stdout;
    if (bytes is List<int> && bytes.isNotEmpty) return bytes;
    throw StateError('TTS $id tidak menghasilkan audio');
  }
}

/// Builds TTS providers from the catalog by id.
class TtsProviderFactory {
  const TtsProviderFactory();

  /// Creates a provider for [id]. [apiKey] is required for hosted providers;
  /// [baseUrl] overrides the default endpoint; [commandTemplate] is required
  /// for the `custom` command provider.
  TtsProvider create(
    String id, {
    String? apiKey,
    String? baseUrl,
    List<String>? commandTemplate,
    String? defaultVoice,
    String? defaultModel,
  }) {
    switch (id) {
      case 'openai-tts':
        return OpenAiTtsProvider(
          apiKey: apiKey ?? '',
          baseUrl: baseUrl ?? 'https://api.openai.com/v1',
          defaultVoice: defaultVoice ?? 'alloy',
        );
      case 'xai':
        return OpenAiTtsProvider(
          apiKey: apiKey ?? '',
          id: 'xai',
          baseUrl: baseUrl ?? 'https://api.x.ai/v1',
          defaultVoice: defaultVoice ?? 'alloy',
        );
      case 'elevenlabs':
        return ElevenLabsTtsProvider(
          apiKey: apiKey ?? '',
          voiceId: defaultVoice ?? '21m00Tcm4TlvDq8ikWAM',
        );
      case 'minimax':
        return HttpTtsProvider(
          config: HttpTtsProviderConfig(
            id: id,
            url: baseUrl ?? 'https://api.minimax.chat/v1/t2a_v2',
            headers: {'authorization': 'Bearer ${apiKey ?? ''}'},
            bodyTemplate: jsonEncode({
              'model': '{{model}}',
              'text': '{{text_json}}',
              'voice_setting': {'voice_id': '{{voice}}'},
            }),
            jsonAudioField: 'data.audio',
            audioEncoding: 'hex',
            defaultVoice: defaultVoice ?? 'male-qn-qingse',
            defaultModel: defaultModel ?? 'speech-02-hd',
          ),
        );
      case 'mistral-voxtral':
        return HttpTtsProvider(
          config: HttpTtsProviderConfig(
            id: id,
            url: baseUrl ?? 'https://api.mistral.ai/v1/audio/speech',
            headers: {'authorization': 'Bearer ${apiKey ?? ''}'},
            bodyTemplate: jsonEncode({
              'model': '{{model}}',
              'input': '{{text_json}}',
              'voice': '{{voice}}',
            }),
            defaultVoice: defaultVoice ?? 'voxtral',
            defaultModel: defaultModel ?? 'voxtral-tts',
          ),
        );
      case 'google-gemini':
        return HttpTtsProvider(
          config: HttpTtsProviderConfig(
            id: id,
            url: baseUrl ??
                'https://generativelanguage.googleapis.com/v1beta/models/'
                    'gemini-2.5-flash-preview-tts:generateContent',
            headers: {'x-goog-api-key': apiKey ?? ''},
            bodyTemplate: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': '{{text_json}}'},
                  ],
                },
              ],
              'generationConfig': {
                'responseModalities': ['AUDIO'],
                'speechConfig': {
                  'voiceConfig': {
                    'prebuiltVoiceConfig': {'voiceName': '{{voice}}'},
                  },
                },
              },
            }),
            jsonAudioField:
                'candidates.0.content.parts.0.inlineData.data',
            audioEncoding: 'base64',
            defaultVoice: defaultVoice ?? 'Kore',
          ),
        );
      case 'neutts':
      case 'kittentts':
        return HttpTtsProvider(
          config: HttpTtsProviderConfig(
            id: id,
            url: baseUrl ?? 'http://127.0.0.1:8080/tts',
            bodyTemplate: jsonEncode({
              'text': '{{text_json}}',
              'voice': '{{voice}}',
            }),
            defaultVoice: defaultVoice,
          ),
        );
      case 'edge-tts':
        return CommandTtsProvider(
          id: id,
          defaultVoice: defaultVoice ?? 'id-ID-ArdiNeural',
          commandTemplate: commandTemplate ??
              [
                'edge-tts',
                '--voice',
                '{{voice}}',
                '--text',
                '{{text_json}}',
                '--write-media',
                '{{output}}',
              ],
        );
      case 'piper':
        return CommandTtsProvider(
          id: id,
          defaultModel: defaultModel ?? 'en_US-amy-medium.onnx',
          commandTemplate: commandTemplate ??
              [
                'sh',
                '-c',
                r'printf %s "$1" | piper --model "$2" --output_file "$3"',
                '--',
                '{{text}}',
                '{{model}}',
                '{{output}}',
              ],
        );
      default:
        if (commandTemplate == null || commandTemplate.isEmpty) {
          throw ArgumentError(
            'Provider TTS tidak dikenal: $id (atau sediakan commandTemplate)',
          );
        }
        return CommandTtsProvider(
          id: id,
          commandTemplate: commandTemplate,
          defaultVoice: defaultVoice,
          defaultModel: defaultModel,
        );
    }
  }
}
