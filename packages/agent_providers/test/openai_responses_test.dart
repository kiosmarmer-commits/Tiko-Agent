
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> capturedBodies;

  setUp(() async {
    capturedBodies = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (req) async {
        final body = await utf8.decoder.bind(req).join();
        capturedBodies
            .add(jsonDecode(body) as Map<String, dynamic>);
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.json;
        if (path.endsWith('/responses') &&
            (jsonDecode(body) as Map<String, dynamic>)['stream'] == true) {
          req.response.headers.contentType =
              ContentType('text', 'event-stream');
          req.response.write(
            'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"Halo"}\n\n',
          );
          req.response.write(
            'event: response.output_item.done\ndata: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"calc","arguments":"{\\"expression\\":\\"1+1\\"}"}}\n\n',
          );
          req.response.write(
            'event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}\n\n',
          );
          await req.response.close();
          return;
        }
        req.response.write(jsonEncode({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Jawaban non-stream'},
              ],
            },
            {
              'type': 'function_call',
              'call_id': 'call_9',
              'name': 'datetime',
              'arguments': '{}',
            },
          ],
          'usage': {'input_tokens': 7, 'output_tokens': 3, 'total_tokens': 10},
        }));
        await req.response.close();
      },
      onError: (Object _) {},
    );
  });

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  });

  OpenAiResponsesProvider provider() => OpenAiResponsesProvider(
        id: 'codex',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'gpt-5-codex',
        apiKey: 'sk-test',
      );

  test('non-stream: teks + function_call + usage', () async {
    final events = await provider()
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'halo')],
          stream: false,
        ))
        .toList();

    final text = events
        .whereType<LlmTextDelta>()
        .map((e) => e.delta)
        .join();
    expect(text, 'Jawaban non-stream');
    final calls = events.whereType<LlmToolCall>().toList();
    expect(calls, hasLength(1));
    expect(calls.first.call.name, 'datetime');
    expect(calls.first.call.id, 'call_9');
    final usage = events.whereType<LlmUsage>().first;
    expect(usage.usage.total, 10);
    expect(events.whereType<LlmDone>(), isNotEmpty);

    final sent = capturedBodies.single;
    expect(sent['model'], 'gpt-5-codex');
    expect(sent['instructions'], isNull);
    expect((sent['input'] as List).first['role'], 'user');
  });

  test('stream SSE: delta text + tool call + usage + done', () async {
    final events = await provider()
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'halo')],
          stream: true,
        ))
        .toList();

    final text = events
        .whereType<LlmTextDelta>()
        .map((e) => e.delta)
        .join();
    expect(text, 'Halo');
    final calls = events.whereType<LlmToolCall>().toList();
    expect(calls, hasLength(1));
    expect(calls.first.call.name, 'calc');
    expect(calls.first.call.args['expression'], '1+1');
    expect(events.whereType<LlmUsage>().first.usage.total, 15);
    expect(events.whereType<LlmDone>(), isNotEmpty);
  });

  test('mapping pesan: system jadi instructions, tool result jadi output',
      () async {
    await provider()
        .chat(const ChatRequest(
          messages: [
            ChatMessage(role: 'system', content: 'Kamu agent.'),
            ChatMessage(role: 'user', content: 'hitung'),
            ChatMessage(
              role: 'assistant',
              content: '',
              toolCalls: [
                ToolCall(id: 'call_1', name: 'calc', args: {'expression': '1+1'}),
              ],
            ),
            ChatMessage(role: 'tool', content: '2', toolCallId: 'call_1'),
          ],
          stream: false,
        ))
        .toList();

    final sent = capturedBodies.single;
    expect(sent['instructions'], 'Kamu agent.');
    final input = sent['input'] as List;
    expect(input[0]['role'], 'user');
    expect(input[1]['type'], 'function_call');
    expect(jsonDecode(input[1]['arguments'] as String)['expression'], '1+1');
    expect(input[2]['type'], 'function_call_output');
    expect(input[2]['call_id'], 'call_1');
    expect(input[2]['output'], '2');
  });

  test('tools dimapping ke format function flat', () async {
    await provider()
        .chat(const ChatRequest(
          messages: [ChatMessage(role: 'user', content: 'x')],
          stream: false,
          tools: [
            ToolSpec(
              name: 'calc',
              description: 'kalkulator',
              inputSchema: {'type': 'object'},
            ),
          ],
        ))
        .toList();

    final tools = capturedBodies.single['tools'] as List;
    expect(tools.first['type'], 'function');
    expect(tools.first['name'], 'calc');
    expect(tools.first['parameters'], {'type': 'object'});
  });
}
