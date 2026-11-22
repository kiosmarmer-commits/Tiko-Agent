import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A.4 — Vision/multimodal: `ChatImage` pada pesan user dikirim ke tiap
/// provider dalam bentuk API asli masing-masing (content array OpenAI,
/// block image Anthropic, inline_data Gemini, images[] Ollama, input_image
/// Responses). Pesan teks biasa TIDAK berubah bentuk (regresi terjaga).
void main() {
  const b64 = 'aGVsbG8gdmlzaW9u'; // "hello vision"

  ChatMessage imgMsg() => const ChatMessage(
        role: 'user',
        content: 'lihat gambar ini',
        images: [ChatImage(base64: b64, mime: 'image/webp')],
      );

  group('openai_compat (streaming SSE)', () {
    late HttpServer server;
    late String baseUrl;
    late List<Map<String, dynamic>> bodies;

    setUp(() async {
      bodies = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}/v1';
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(body) as Map<String, dynamic>);
        req.response.headers.contentType =
            ContentType('text', 'event-stream');
        req.response.write('data: ${jsonEncode({
              'choices': [
                {'delta': {'content': 'terlihat'}},
              ],
            })}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      }, onError: (Object _) {});
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('pesan user ber-gambar dikirim sebagai content array image_url',
        () async {
      final p = OpenAiCompatProvider(
        id: 'vis', baseUrl: baseUrl, model: 'm',
        apiKey: 'k' * 32,
      );
      await p
          .chat(ChatRequest(messages: [imgMsg()], stream: true))
          .toList();
      final msg = (bodies.single['messages'] as List).single
          as Map<String, dynamic>;
      final content = msg['content'] as List<dynamic>;
      expect(content[0], {
        'type': 'text',
        'text': 'lihat gambar ini',
      });
      expect(content[1]['type'], 'image_url');
      expect(content[1]['image_url']['url'], 'data:image/webp;base64,$b64');
    });

    test('pesan tanpa gambar tetap bentuk lama (tidak ada array content)',
        () async {
      final p = OpenAiCompatProvider(
        id: 'vis', baseUrl: baseUrl, model: 'm',
        apiKey: 'k' * 32,
      );
      await p
          .chat(const ChatRequest(
            messages: [ChatMessage(role: 'user', content: 'teks saja')],
            stream: true,
          ))
          .toList();
      final msg = (bodies.single['messages'] as List).single
          as Map<String, dynamic>;
      expect(msg['content'], 'teks saja');
    });
  });

  group('anthropic', () {
    test('pesan ber-gambar → blok type=image base64', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'terlihat'},
            ],
            'usage': {'input_tokens': 3, 'output_tokens': 2},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final p = AnthropicProvider(apiKey: 'k', httpClient: client);
      final events = await p
          .chat(ChatRequest(messages: [imgMsg()]))
          .toList();
      final msg = (captured!['messages'] as List).single
          as Map<String, dynamic>;
      final content = msg['content'] as List<dynamic>;
      expect(content[0], {'type': 'text', 'text': 'lihat gambar ini'});
      expect(content[1]['type'], 'image');
      expect(content[1]['source']['type'], 'base64');
      expect(content[1]['source']['media_type'], 'image/webp');
      expect(content[1]['source']['data'], b64);
      expect(events.whereType<LlmTextDelta>().isNotEmpty, isTrue);
    });

    test('pesan tanpa gambar tetap content string', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'content': [
              {'type': 'text', 'text': 'x'},
            ]}),
            200,
            headers: {'content-type': 'application/json'});
      });
      final p = AnthropicProvider(apiKey: 'k', httpClient: client);
      await p
          .chat(const ChatRequest(
            messages: [ChatMessage(role: 'user', content: 'teks saja')],
          ))
          .toList();
      final msg = (captured!['messages'] as List).single
          as Map<String, dynamic>;
      expect(msg['content'], 'teks saja');
    });
  });

  group('gemini', () {
    test('pesan ber-gambar → inline_data di parts', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'terlihat'},
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final p = GeminiProvider(apiKey: 'k', httpClient: client);
      final events = await p
          .chat(ChatRequest(messages: [imgMsg()]))
          .toList();
      final content = (captured!['contents'] as List).single
          as Map<String, dynamic>;
      final parts = content['parts'] as List<dynamic>;
      expect(parts[0], {'text': 'lihat gambar ini'});
      expect(parts[1]['inline_data']['mime_type'], 'image/webp');
      expect(parts[1]['inline_data']['data'], b64);
      expect(events.whereType<LlmTextDelta>().isNotEmpty, isTrue);
    });

    test('pesan tanpa gambar → parts hanya text', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'candidates': [
              {'content': {'parts': [
                {'text': 'x'},
              ]}},
            ]}),
            200,
            headers: {'content-type': 'application/json'});
      });
      final p = GeminiProvider(apiKey: 'k', httpClient: client);
      await p
          .chat(const ChatRequest(
            messages: [ChatMessage(role: 'user', content: 'teks saja')],
          ))
          .toList();
      final parts = ((captured!['contents'] as List).single
          as Map<String, dynamic>)['parts'] as List<dynamic>;
      expect(parts, hasLength(1));
      expect(parts.single, {'text': 'teks saja'});
    });
  });

  group('ollama_native', () {
    test('pesan ber-gambar → field images[] base64', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'terlihat'},
            'done': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final p = OllamaNativeProvider(client: client);
      final events = await p
          .chat(ChatRequest(messages: [imgMsg()], stream: false))
          .toList();
      final msg = (captured!['messages'] as List).single
          as Map<String, dynamic>;
      expect(msg['content'], 'lihat gambar ini');
      expect(msg['images'], [b64]);
      expect(events.whereType<LlmTextDelta>().isNotEmpty, isTrue);
    });

    test('pesan tanpa gambar tidak punya field images', () async {
      Map<String, dynamic>? captured;
      final client = MockClient((req) async {
        captured = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'message': {'role': 'assistant', 'content': 'x'},
                'done': true}),
            200,
            headers: {'content-type': 'application/json'});
      });
      final p = OllamaNativeProvider(client: client);
      await p
          .chat(const ChatRequest(
            messages: [ChatMessage(role: 'user', content: 'teks saja')],
            stream: false,
          ))
          .toList();
      final msg = (captured!['messages'] as List).single
          as Map<String, dynamic>;
      expect(msg.containsKey('images'), isFalse);
    });
  });

  group('openai_responses', () {
    test('pesan tanpa gambar → input_image dengan data URL', () async {
      late HttpServer server;
      late List<Map<String, dynamic>> bodies;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      bodies = [];
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(body) as Map<String, dynamic>);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'terlihat'},
              ],
            },
          ],
          'usage': {
            'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2,
          },
        }));
        await req.response.close();
      }, onError: (Object _) {});
      addTearDown(() => server.close(force: true));

      final p = OpenAiResponsesProvider(
        id: 'codex',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'm',
        apiKey: 'k' * 32,
      );
      await p.chat(ChatRequest(messages: [imgMsg()])).toList();
      final input = bodies.single['input'] as List<dynamic>;
      final item = input.single as Map<String, dynamic>;
      final content = item['content'] as List<dynamic>;
      expect(content[0], {'type': 'input_text', 'text': 'lihat gambar ini'});
      expect(content[1]['type'], 'input_image');
      expect(content[1]['image_url'], 'data:image/webp;base64,$b64');
    });
  });
}
