import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// F6 (docs/15 §7) — Gemini STT provider (generateContent + inline_data,
/// bukan jalur OpenAI-compat): fallback chain + parsing defensif respons.
void main() {
  late HttpServer server;
  late String baseUrl;
  late List<Map<String, String>> seen;

  setUp(() async {
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1beta';
    server.listen((req) async {
      final ct = req.headers.value('content-type') ?? '';
      final apiKey = req.headers.value('x-goog-api-key') ?? '';
      final raw = await utf8.decoder.bind(req).join();
      seen.add({'api_key': apiKey, 'ct': ct, 'raw': raw, 'path': req.uri.path});
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'halo dunia dari gemini'},
              ],
            },
          },
        ],
      }));
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('gemini dipilih saat kunci ada; inline_data base64 + parse candidates',
      () async {
    final dir = Directory.systemTemp.createTempSync();
    final path = '${dir.path}/audio.mp3';
    final audioBytes = List.filled(16, 0x37);
    await File(path).writeAsBytes(audioBytes);

    final client = SttClient(
      geminiApiKey: 'gm-test-key',
      geminiBaseUrl: baseUrl,
    );
    final text = await client.transcribeFile(path);
    expect(text, 'halo dunia dari gemini');
    expect(seen, hasLength(1));
    expect(seen.single['api_key'], 'gm-test-key');
    expect(seen.single['ct'], contains('application/json'));
    expect(seen.single['path'], contains('/v1beta/models/gemini-2.0-flash:'));
    final body = jsonDecode(seen.single['raw']!) as Map<String, dynamic>;
    final parts = (((body['contents'] as List).first
        as Map<String, dynamic>)['parts'] as List)
        .cast<Map<String, dynamic>>();
    expect(parts.first['text'], contains('Transcribe'));
    final inline = parts.last['inline_data'] as Map<String, dynamic>;
    expect(inline['mime_type'], 'audio/mp3');
    expect(base64Decode(inline['data'] as String), audioBytes);
    dir.deleteSync(recursive: true);
  });

  test('groq HTTP 500 -> null, chain lanjut ke gemini (fallback jalan)',
      () async {
    final dir = Directory.systemTemp.createTempSync();
    final path = '${dir.path}/audio.wav';
    await File(path).writeAsBytes(List.filled(8, 0x30));
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root = 'http://127.0.0.1:${server.port}';
    var geminiHits = 0;
    var groqHits = 0;
    server.listen((req) async {
      if (req.uri.path.contains('/fail')) {
        groqHits++;
        req.response.statusCode = 500;
        req.response.write('groq meledak');
        await req.response.close();
        return;
      }
      if (req.headers.value('x-goog-api-key') == 'gm-test') {
        geminiHits++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'fallback ke gemini'},
                ],
              },
            },
          ],
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    final client = SttClient(
      geminiApiKey: 'gm-test',
      geminiBaseUrl: '$root/ok/v1beta',
      geminiModel: 'gemini-2.5-flash',
      groqApiKey: 'gq-test',
      groqBaseUrl: '$root/fail/v1',
    );
    final text = await client.transcribeFile(path);
    expect(groqHits, 1);
    expect(geminiHits, 1);
    expect(text, 'fallback ke gemini');
    dir.deleteSync(recursive: true);
  });

  test('tanpa kunci apapun -> null tanpa crash', () async {
    final dir = Directory.systemTemp.createTempSync();
    final path = '${dir.path}/audio.mp3';
    await File(path).writeAsBytes(List.filled(8, 0x30));
    final client = SttClient();
    expect(await client.transcribeFile(path), isNull);
    dir.deleteSync(recursive: true);
  });
}
