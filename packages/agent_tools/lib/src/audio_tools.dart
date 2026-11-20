import 'dart:convert';
import 'dart:io';
import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

// ==========================================
// TEXT-TO-SPEECH (TTS) PROVIDERS
// ==========================================

abstract class TTSProvider {
  String get name;
  Future<List<int>> synthesize(String text, {String voice = 'default'});
}

/// 1. Edge/Google TTS Provider (Default, Gratis, Stabil)
class EdgeTTSProvider implements TTSProvider {
  @override
  String get name => 'edge';

  @override
  Future<List<int>> synthesize(String text, {String voice = 'id-ID'}) async {
    final client = http.Client();
    try {
      final lang = voice.split('-').take(2).join('-');
      final uri = Uri.parse('https://translate.google.com/translate_tts').replace(queryParameters: {
        'ie': 'UTF-8',
        'q': text,
        'tl': lang,
        'client': 'tw-ob',
      });
      final response = await client.get(uri, headers: {'User-Agent': 'Mozilla/5.0'});
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      throw Exception('TTS failed: ${response.statusCode}');
    } finally {
      client.close();
    }
  }
}

/// 2. ElevenLabs TTS Provider (Kualitas Tinggi, Berbayar)
class ElevenLabsTTSProvider implements TTSProvider {
  @override
  String get name => 'elevenlabs';
  final String apiKey;
  final String voiceId;

  ElevenLabsTTSProvider({required this.apiKey, this.voiceId = 'pNInz6obpgDQGcFmaJgB'});

  @override
  Future<List<int>> synthesize(String text, {String voice = 'default'}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId');
      final response = await client.post(
        uri,
        headers: {
          'xi-api-key': apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'text': text,
          'model_id': 'eleven_monolingual_v1',
          'voice_settings': {'stability': 0.5, 'similarity_boost': 0.75},
        }),
      );
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      throw Exception('ElevenLabs TTS failed: ${response.statusCode} ${response.body}');
    } finally {
      client.close();
    }
  }
}

/// 3. OpenAI TTS Provider (Berbayar)
class OpenAITTSProvider implements TTSProvider {
  @override
  String get name => 'openai';
  final String apiKey;

  OpenAITTSProvider({required this.apiKey});

  @override
  Future<List<int>> synthesize(String text, {String voice = 'alloy'}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.openai.com/v1/audio/speech');
      final response = await client.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': 'tts-1',
          'input': text,
          'voice': voice,
          'response_format': 'mp3',
        }),
      );
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      throw Exception('OpenAI TTS failed: ${response.statusCode} ${response.body}');
    } finally {
      client.close();
    }
  }
}

// ==========================================
// SPEECH-TO-TEXT (STT) PROVIDERS
// ==========================================

abstract class STTProvider {
  String get name;
  Future<String> transcribe(List<int> audioData, {String format = 'wav'});
}

/// 1. Groq Whisper STT Provider (Default, Cepat, Gratis/Berbayar)
class GroqWhisperSTTProvider implements STTProvider {
  @override
  String get name => 'groq';
  final String apiKey;

  GroqWhisperSTTProvider({required this.apiKey});

  @override
  Future<String> transcribe(List<int> audioData, {String format = 'wav'}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          audioData,
          filename: 'audio.$format',
        ))
        ..fields['model'] = 'whisper-large-v3';
      
      final response = await request.send();
      final respStr = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        return data['text'] as String;
      }
      throw Exception('Groq STT failed: ${response.statusCode} $respStr');
    } finally {
      client.close();
    }
  }
}

/// 2. OpenAI Whisper STT Provider (Berbayar)
class OpenAIWhisperSTTProvider implements STTProvider {
  @override
  String get name => 'openai';
  final String apiKey;

  OpenAIWhisperSTTProvider({required this.apiKey});

  @override
  Future<String> transcribe(List<int> audioData, {String format = 'wav'}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          audioData,
          filename: 'audio.$format',
        ))
        ..fields['model'] = 'whisper-1';
      
      final response = await request.send();
      final respStr = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        final data = jsonDecode(respStr) as Map<String, dynamic>;
        return data['text'] as String;
      }
      throw Exception('OpenAI STT failed: ${response.statusCode} $respStr');
    } finally {
      client.close();
    }
  }
}

/// 3. Local Whisper STT Provider (Fallback, Gratis, memerlukan whisper.cpp/CLI)
class LocalWhisperSTTProvider implements STTProvider {
  @override
  String get name => 'local';
  final String whisperCommand;

  LocalWhisperSTTProvider({this.whisperCommand = 'whisper'});

  @override
  Future<String> transcribe(List<int> audioData, {String format = 'wav'}) async {
    final tempFile = File('${Directory.systemTemp.path}/tiko_stt_${DateTime.now().millisecondsSinceEpoch}.$format');
    await tempFile.writeAsBytes(audioData);
    
    try {
      final result = await Process.run(whisperCommand, [tempFile.path, '--output-format', 'txt']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
      throw Exception('Local Whisper failed: ${result.stderr}');
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
}

// ==========================================
// AUDIO TOOLS
// ==========================================

class TextToSpeechTool implements Tool {
  final TTSProvider provider;

  TextToSpeechTool({required this.provider});

  @override
  ToolSpec get spec => ToolSpec(
        name: 'text_to_speech',
        description: 'Ubah teks menjadi suara (audio). Mengembalikan path file audio.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': 'Teks yang akan diubah menjadi suara'},
            'voice': {'type': 'string', 'description': 'ID atau nama suara (opsional)', 'default': 'default'},
          },
          'required': ['text'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final text = args['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        return ToolResult(callId: '', content: 'text wajib diisi', isError: true);
      }
      final voice = args['voice'] as String? ?? 'default';
      
      final audioBytes = await provider.synthesize(text, voice: voice);
      final tempFile = File('${Directory.systemTemp.path}/tiko_tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
      await tempFile.writeAsBytes(audioBytes);
      
      return ToolResult(
        callId: '',
        content: 'Audio berhasil dibuat menggunakan ${provider.name}. Path: ${tempFile.path}',
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'Error saat TTS: ${e.toString()}',
        isError: true,
      );
    }
  }
}

class SpeechToTextTool implements Tool {
  final STTProvider provider;

  SpeechToTextTool({required this.provider});

  @override
  ToolSpec get spec => ToolSpec(
        name: 'speech_to_text',
        description: 'Ubah file audio menjadi teks (transkripsi).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'file_path': {'type': 'string', 'description': 'Path ke file audio'},
            'format': {'type': 'string', 'description': 'Format audio (wav, mp3, dll)', 'default': 'wav'},
          },
          'required': ['file_path'],
        },
        risk: 'low',
        parallelSafe: true,
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final filePath = args['file_path'] as String?;
      if (filePath == null || filePath.trim().isEmpty) {
        return ToolResult(callId: '', content: 'file_path wajib diisi', isError: true);
      }
      final format = args['format'] as String? ?? 'wav';
      
      final file = File(filePath);
      if (!await file.exists()) {
        return ToolResult(callId: '', content: 'File tidak ditemukan: $filePath', isError: true);
      }
      
      final audioBytes = await file.readAsBytes();
      final text = await provider.transcribe(audioBytes, format: format);
      
      return ToolResult(
        callId: '',
        content: 'Transkripsi berhasil (via ${provider.name}):\n\n$text',
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: 'Error saat STT: ${e.toString()}',
        isError: true,
      );
    }
  }
}
