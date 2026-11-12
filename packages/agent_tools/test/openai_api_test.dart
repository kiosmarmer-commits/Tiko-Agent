import 'dart:convert';

import 'package:agent_tools/agent_tools.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  Future<(OpenAiCompatServer, Uri)> startServer() async {
    final server = OpenAiCompatServer(
      config: const OpenAiCompatConfig(
          apiKey: 'test-key-123', models: ['tiko-agent']),
      handler: (req) async =>
          'balasan untuk: ${req.lastUserText}',
    );
    await server.start();
    return (server, Uri.parse('http://127.0.0.1:${server.port}'));
  }

  test('health endpoint is open without auth', () async {
    final (server, base) = await startServer();
    final res = await http.get(base.replace(path: '/health'));
    expect(res.statusCode, 200);
    expect(jsonDecode(res.body)['status'], 'ok');
    await server.stop();
  });

  test('missing bearer token is rejected', () async {
    final (server, base) = await startServer();
    final res = await http.post(base.replace(path: '/v1/chat/completions'),
        body: jsonEncode({'messages': []}),
        headers: {'Content-Type': 'application/json'});
    expect(res.statusCode, 401);
    expect(jsonDecode(res.body)['error']['type'], 'authentication_error');
    await server.stop();
  });

  test('models endpoint lists models', () async {
    final (server, base) = await startServer();
    final res = await http.get(base.replace(path: '/v1/models'),
        headers: {'Authorization': 'Bearer test-key-123'});
    expect(res.statusCode, 200);
    final data = jsonDecode(res.body)['data'] as List;
    expect(data.single['id'], 'tiko-agent');
    await server.stop();
  });

  test('non-streaming chat completion returns OpenAI format', () async {
    final (server, base) = await startServer();
    final res = await http.post(
      base.replace(path: '/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer test-key-123',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'tiko-agent',
        'messages': [
          {'role': 'system', 'content': 'kamu asisten'},
          {'role': 'user', 'content': 'halo dunia'},
        ],
      }),
    );
    expect(res.statusCode, 200);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    expect(json['object'], 'chat.completion');
    expect((json['id'] as String).startsWith('chatcmpl-'), isTrue);
    final choice = (json['choices'] as List).single;
    expect(choice['message']['content'], 'balasan untuk: halo dunia');
    expect(json['usage']['total_tokens'], greaterThan(0));
    await server.stop();
  });

  test('streaming chat completion emits SSE chunks and [DONE]', () async {
    final (server, base) = await startServer();
    final client = http.Client();
    final req = http.Request(
      'POST',
      base.replace(path: '/v1/chat/completions'),
    )
      ..headers['Authorization'] = 'Bearer test-key-123'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': 'tiko-agent',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'stream tolong'},
        ],
      });
    final res = await client.send(req);
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], contains('text/event-stream'));
    final body = await res.stream.transform(utf8.decoder).join();
    final lines = body
        .split('\n')
        .where((l) => l.startsWith('data: '))
        .map((l) => l.substring(6))
        .toList();
    expect(lines.last, '[DONE]');
    final chunks = lines
        .take(lines.length - 1)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    final content = chunks
        .map((c) => ((c['choices'] as List).first
            as Map)['delta'] as Map)
        .map((d) => d['content'] as String? ?? '')
        .join();
    expect(content, 'balasan untuk: stream tolong');
    expect(
      (chunks.last['choices'] as List).first['finish_reason'],
      isNotNull,
    );
    client.close();
    await server.stop();
  });

  test('invalid json body returns 400', () async {
    final (server, base) = await startServer();
    final res = await http.post(base.replace(path: '/v1/chat/completions'),
        headers: {'Authorization': 'Bearer test-key-123'}, body: '{nope');
    expect(res.statusCode, 400);
    await server.stop();
  });

  test('handler failure returns 500 in OpenAI error format', () async {
    final server = OpenAiCompatServer(
      config: const OpenAiCompatConfig(apiKey: 'k'),
      handler: (req) async => throw StateError('boom'),
    );
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final res = await http.post(
      base.replace(path: '/v1/chat/completions'),
      headers: {'Authorization': 'Bearer k'},
      body: jsonEncode({
        'messages': [
          {'role': 'user', 'content': 'x'},
        ],
      }),
    );
    expect(res.statusCode, 500);
    expect(jsonDecode(res.body)['error']['type'], 'server_error');
    await server.stop();
  });

  test('unknown path returns 404', () async {
    final (server, base) = await startServer();
    final res = await http.get(base.replace(path: '/v1/unknown'),
        headers: {'Authorization': 'Bearer test-key-123'});
    expect(res.statusCode, 404);
    await server.stop();
  });
}
