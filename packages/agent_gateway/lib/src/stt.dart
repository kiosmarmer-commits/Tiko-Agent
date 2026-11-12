import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Speech-to-text: local whisper binary or OpenAI-compatible audio API.
class SttClient {
  SttClient({
    this.whisperBin,
    this.apiBaseUrl,
    this.apiKey,
    this.model = 'whisper-1',
    http.Client? httpClient,
  }) : _http = httpClient;

  final String? whisperBin;
  final String? apiBaseUrl;
  final String? apiKey;
  final String model;
  final http.Client? _http;

  Future<String?> transcribeFile(String path) async {
    if (whisperBin != null && whisperBin!.isNotEmpty) {
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
      } catch (_) {}
    }
    if (apiBaseUrl != null && apiKey != null) {
      final client = _http ?? http.Client();
      try {
        final uri = Uri.parse('$apiBaseUrl/audio/transcriptions');
        final req = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..fields['model'] = model
          ..files.add(await http.MultipartFile.fromPath('file', path));
        final streamed = await req.send().timeout(const Duration(seconds: 120));
        final body = await streamed.stream.bytesToString();
        if (streamed.statusCode >= 400) return null;
        final json = jsonDecode(body) as Map<String, dynamic>;
        return (json['text'] as String?)?.trim();
      } catch (_) {
        return null;
      } finally {
        if (_http == null) client.close();
      }
    }
    return null;
  }
}
