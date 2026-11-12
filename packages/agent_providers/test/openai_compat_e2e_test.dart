import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

/// E2E test of [OpenAiCompatProvider] against a mock OpenAI-compatible
/// server on loopback: real HTTP over the wire, no external service.
void main() {
  late HttpServer server;
  late String baseUrl;
  final received = <({String path, String? auth, Map<String, dynamic> body})>[];

  setUp(() async {
    received.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (req) async {
        final body = await utf8.decoder.bind(req).join();
        received.add((
          path: req.uri.path,
          auth: req.headers.value('Authorization'),
          body: body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>,
        ));
        if (req.uri.path == '/v1/chat/completions') {
          final payload = jsonDecode(body) as Map<String, dynamic>;
          if (payload['stream'] == true) {
            req.response.headers.contentType =
                ContentType('text', 'event-stream');
            req.response.write('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'Halo '},
                    },
                  ],
                })}\n\n');
            req.response.write('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'dari mock!'},
                    },
                  ],
                  'usage': {
                    'prompt_tokens': 11,
                    'completion_tokens': 7,
                    'total_tokens': 18,
                  },
                })}\n\n');
            req.response.write('data: [DONE]\n\n');
            await req.response.close();
          } else {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'Jawaban non-stream',
                  },
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 5,
                'completion_tokens': 3,
                'total_tokens': 8,
              },
            }));
            await req.response.close();
          }
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      },
      onError: (Object _) {},
    );
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  OpenAiCompatProvider provider() => OpenAiCompatProvider(
        id: 'mock-openai',
        baseUrl: baseUrl,
        model: 'mock-model',
        apiKey: 'k' * 32,
      );

  test('non-streaming completion returns text and usage', () async {
    final events = await provider()
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'ping')],
          stream: false,
        ))
        .toList();

    expect(received, hasLength(1));
    expect(received.single.path, '/v1/chat/completions');
    expect(received.single.auth, 'Bearer ${'k' * 32}');
    expect(received.single.body['model'], 'mock-model');

    expect(events.whereType<LlmTextDelta>().map((e) => e.delta).join(),
        'Jawaban non-stream');
    expect(events.whereType<LlmDone>(), isNotEmpty);
    final usage = events.whereType<LlmUsage>().toList();
    expect(usage, hasLength(1));
    expect(usage.single.usage.total, 8);
  });

  test('streaming completion accumulates deltas, usage and done', () async {
    final events = await provider()
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'ping')],
          stream: true,
        ))
        .toList();

    final text = events.whereType<LlmTextDelta>().map((e) => e.delta).join();
    expect(text, 'Halo dari mock!');
    final usage = events.whereType<LlmUsage>().toList();
    expect(usage, hasLength(1));
    expect(usage.single.usage.prompt, 11);
    expect(usage.single.usage.completion, 7);
    expect(events.last, isA<LlmDone>());
  });

  test('tool definitions are sent and tool calls are parsed', () async {
    await server.close(force: true);
    final toolServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    toolServer.listen(
      (req) async {
        await utf8.decoder.bind(req).drain();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'read_file',
                      'arguments': '{"path": "/tmp/a.txt"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }));
        await req.response.close();
      },
      onError: (Object _) {},
    );
    final p = OpenAiCompatProvider(
      id: 'mock-openai',
      baseUrl: 'http://127.0.0.1:${toolServer.port}/v1',
      model: 'mock-model',
    );
    addTearDown(() => toolServer.close(force: true));

    final events = await p
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'baca file')],
          stream: false,
          tools: [
            ToolSpec(
              name: 'read_file',
              description: 'baca',
              inputSchema: {'type': 'object'},
            ),
          ],
        ))
        .toList();

    final calls = events.whereType<LlmToolCall>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.call.name, 'read_file');
    expect(calls.single.call.args['path'], '/tmp/a.txt');
  });

  test('HTTP 500 surfaces as LlmError with status code', () async {
    await server.close(force: true);
    final errServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    errServer.listen(
      (req) async {
        await utf8.decoder.bind(req).drain();
        req.response.statusCode = 500;
        req.response.write(jsonEncode({
          'error': {'message': 'mock overload'},
        }));
        await req.response.close();
      },
      onError: (Object _) {},
    );
    addTearDown(() => errServer.close(force: true));
    final p = OpenAiCompatProvider(
      id: 'mock-openai',
      baseUrl: 'http://127.0.0.1:${errServer.port}/v1',
      model: 'mock-model',
    );

    final events = await p
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'ping')],
          stream: false,
        ))
        .toList();

    expect(events.whereType<LlmError>(), hasLength(1));
    expect(events.whereType<LlmError>().single.code, '500');
  });
}
