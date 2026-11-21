import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// P4 Hermes-parity: endpoint OpenAI-compat POST /v1/chat/completions —
/// komposisi prompt (system + transcript + user terakhir), respons
/// non-stream & streaming SSE, validasi fail-closed, dan error shape
/// OpenAI (`error.{message,type,code}`).
void main() {
  late HttpApiServer server;
  String? lastText;
  String? lastSession;
  String? lastUser;
  Map<String, Object?>? lastMeta;

  setUp(() async {
    lastText = null;
    lastSession = null;
    lastUser = null;
    lastMeta = null;
    server = HttpApiServer(
      onMessage: (msg) async {
        lastText = msg.text;
        lastSession = msg.sessionKey;
        lastUser = msg.userKey;
        lastMeta = msg.meta;
        return 'balasan: ${msg.text}';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<(HttpClientResponse, String)> send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final request = await client.openUrl(method, uri);
      if (auth) {
        request.headers.set(
          'authorization',
          'Bearer manager-token-0123456789abcdef',
        );
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response, text);
    } finally {
      client.close(force: true);
    }
  }

  test('non-stream: shape chat.completion, id chatcmpl-, usage > 0', () async {
    final (res, text) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'halo tiko'},
      ],
    });
    expect(res.statusCode, 200);
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['object'], 'chat.completion');
    expect((decoded['id'] as String).startsWith('chatcmpl-'), isTrue);
    expect(decoded['model'], 'tiko-agent');
    final choices = decoded['choices'] as List;
    expect(choices, hasLength(1));
    final message = (choices.first as Map)['message'] as Map;
    expect(message['role'], 'assistant');
    expect(message['content'], 'balasan: halo tiko');
    final usage = decoded['usage'] as Map;
    expect((usage['prompt_tokens'] as num) > 0, isTrue);
    expect((usage['completion_tokens'] as num) > 0, isTrue);
    expect((usage['total_tokens'] as num) > 0, isTrue);
  });

  test('stream: text/event-stream + chunks + data: [DONE]', () async {
    final (res, text) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'halo stream'},
      ],
      'stream': true,
    });
    expect(res.statusCode, 200);
    expect(
      res.headers.value('content-type')!.startsWith('text/event-stream'),
      isTrue,
    );
    expect(text.contains('data: '), isTrue);
    expect(text.contains('chat.completion.chunk'), isTrue);
    expect(text.contains('finish_reason":"stop"'), isTrue);
    expect(text.endsWith('data: [DONE]\n\n'), isTrue);
  });

  test('400 bila messages kosong / tidak ada', () async {
    for (final body in [
      <String, dynamic>{},
      <String, dynamic>{'messages': <dynamic>[]},
      <String, dynamic>{'messages': 'bukan-list'},
    ]) {
      final (res, text) = await send('POST', '/v1/chat/completions', body: body);
      expect(res.statusCode, 400, reason: text);
      final err = (jsonDecode(text) as Map)['error'] as Map;
      expect(err['type'], 'invalid_request_error');
      expect(err['message'], isNotEmpty);
      expect((err['code'] as String), isNotEmpty);
    }
  });

  test('400 bila role tool/function / format invalid (fail-closed)', () async {
    for (final messages in [
      [
        {'role': 'tool', 'content': 'hasil tool'},
        {'role': 'user', 'content': 'lanjut'},
      ],
      [
        {'role': 'function', 'content': 'x'},
        {'role': 'user', 'content': 'lanjut'},
      ],
      [
        {'role': 'user'},
      ],
      [
        {'role': 'user', 'content': 123},
      ],
      [
        'bukan-map',
        {'role': 'user', 'content': 'x'},
      ],
      [
        {'role': 'assistant', 'content': 'tanpa user'},
      ],
    ]) {
      final (res, text) = await send('POST', '/v1/chat/completions', body: {
        'messages': messages,
      });
      expect(res.statusCode, 400, reason: text);
    }
  });

  test('401 tanpa auth', () async {
    final (res, _) = await send('POST', '/v1/chat/completions',
        body: {
          'messages': [
            {'role': 'user', 'content': 'x'},
          ],
        },
        auth: false);
    expect(res.statusCode, 401);
  });

  test('multi-message: system + transcript + user terakhir dominan', () async {
    final (res, text) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {
          'role': 'system',
          'content': 'Kamu asisten ringkas.',
        },
        {'role': 'user', 'content': 'siapa kamu'},
        {'role': 'assistant', 'content': 'saya Tiko'},
        {'role': 'user', 'content': 'apa itu cron'},
        {'role': 'assistant', 'content': 'cron penjadwal'},
        {'role': 'user', 'content': 'buatkan cron harian'},
      ],
      'model': 'gemini/gemini-2.0-flash',
      'session_key': 'openai:proj-1',
      'user_key': 'budi',
    });
    expect(res.statusCode, 200, reason: text);
    final prompt = lastText!;
    expect(prompt.startsWith('[system]'), isTrue);
    expect(prompt.contains('[/system]'), isTrue);
    expect(prompt.contains('Kamu asisten ringkas.'), isTrue);
    expect(prompt.contains('[transcript percakapan sebelumnya'), isTrue);
    expect(prompt.contains('[/transcript]'), isTrue);
    expect(prompt.contains('User: siapa kamu'), isTrue);
    expect(prompt.contains('Assistant: saya Tiko'), isTrue);
    expect(prompt.contains('User: apa itu cron'), isTrue);
    expect(prompt.contains('Assistant: cron penjadwal'), isTrue);
    expect(prompt.trim().endsWith('buatkan cron harian'), isTrue);
    expect(lastMeta!.containsKey('source'), isTrue);
    expect(lastMeta!['source'], 'openai_compat');
    expect(lastMeta!['requested_model'], 'gemini/gemini-2.0-flash');
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['model'], 'gemini/gemini-2.0-flash');
  });

  test('content parts array (multimodal text parts) didukung', () async {
    final (res, text) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'bagian satu '},
            {'type': 'text', 'text': 'bagian dua'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'terima kasih'},
          ],
        },
        {'role': 'user', 'content': 'lanjutkan'},
      ],
    });
    expect(res.statusCode, 200, reason: text);
    expect(lastText!.contains('bagian satu \nbagian dua'), isTrue);
    expect(lastText!.contains('Assistant: terima kasih'), isTrue);
    expect(lastMeta!['source'], 'openai_compat');
  });

  test('model echo persis / default tiko-agent', () async {
    final (res1, text1) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'x'},
      ],
      'model': 'gpt-4o-mini',
    });
    expect(res1.statusCode, 200);
    expect((jsonDecode(text1) as Map)['model'], 'gpt-4o-mini');
    final (res2, text2) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'x'},
      ],
      'model': '',
    });
    expect(res2.statusCode, 200);
    expect((jsonDecode(text2) as Map)['model'], 'tiko-agent');
  });

  test('session/user default openai:default + openai, channel http', () async {
    final (res, _) = await send('POST', '/v1/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'cek sesi'},
      ],
    });
    expect(res.statusCode, 200);
    expect(lastSession, 'openai:default');
    expect(lastUser, 'openai');
    expect(lastMeta!['source'], 'openai_compat');
  });

  test('body JSON bukan object / invalid → 400', () async {
    final (res1, text1) = await send('POST', '/v1/chat/completions', body: [1, 2]);
    expect(res1.statusCode, 400, reason: text1);
    final err = (jsonDecode(text1) as Map)['error'] as Map;
    expect(err, isNotNull);
  });
}
