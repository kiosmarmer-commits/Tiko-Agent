import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// F6 (docs/15 §7) — MiniMax STT provider (asr-1.0, POST /v1/speech_to_text):
/// fallback chain + parsing defensif respons (`text` top-level atau nested).
void main() {
  late HttpServer server;
  late String baseUrl;
  late List<Map<String, String>> seen;

  setUp(() async {
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
    server.listen((req) async {
      final ct = req.headers.value('content-type') ?? '';
      final auth = req.headers.value('authorization') ?? '';
      final raw = await utf8.decoder.bind(req).join();
      seen.add({'auth': auth, 'ct': ct, 'raw': raw});
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'base_resp': {'status_code': 0},
        'data': {'text': 'halo dunia dari minimax'},
      }));
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('minimax dipilih ketika kunci tersedia, hasil diparse dari data.text',
      () async {
    final dir = Directory.systemTemp.createTempSync();
    final path = '${dir.path}/audio.mp3';
    await File(path).writeAsBytes(List.filled(16, 0x30));

    final client = SttClient(
      minimaxApiKey: 'mm-test-key',
      minimaxBaseUrl: baseUrl,
      httpClient: null,
    );
    final text = await client.transcribeFile(path);
    expect(text, 'halo dunia dari minimax');
    expect(seen, hasLength(1));
    expect(seen.single['auth'], 'Bearer mm-test-key');
    expect(seen.single['ct'], contains('multipart/form-data'));
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
