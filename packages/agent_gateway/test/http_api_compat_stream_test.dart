import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// S19-B: POST /v1/chat/completions dengan stream=true mengalirkan
/// delta token-level (frame chat.delta direlay sebagai
/// chat.completion.chunk) + usage token nyata via frame chat.usage.
/// Tanpa handler progress, jalur satu-potong lama tetap jalan.
void main() {
  late HttpApiServer server;
  final finger = DateTime.now().microsecondsSinceEpoch.toString();

  setUp(() async {
    server = HttpApiServer(
      onMessage: (msg) async => 'jawaban tunggal $finger',
      onMessageWithProgress: (msg, progress) async {
        progress({'type': 'chat.status', 'state': 'running'});
        progress({'type': 'chat.delta', 'text': 'Halo, '});
        progress({'type': 'chat.delta', 'text': 'ini jawaban $finger'});
        progress({'type': 'chat.usage', 'tokens': 421});
        return 'Halo, ini jawaban $finger';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<(HttpClientResponse, String)> post(Map<String, dynamic> body,
      {bool stream = false}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse(
            'http://127.0.0.1:${server.boundPort}/v1/chat/completions'),
      );
      req.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({...body, 'stream': stream})));
      final res = await req.close();
      final raw = await res.transform(utf8.decoder).join();
      return (res, raw);
    } finally {
      client.close(force: true);
    }
  }

  test('stream=true: delta token-level, bukan satu potong', () async {
    final (res, raw) = await post({
      'messages': [
        {'role': 'user', 'content': 'sapa'},
      ],
    }, stream: true);
    expect(res.headers.contentType?.mimeType, 'text/event-stream');
    final frames = <Map<String, dynamic>>[
      for (final chunk in raw.split('\n\n'))
        if (chunk.startsWith('data: '))
          if (chunk.substring('data: '.length).trim() != '[DONE]')
            Map<String, dynamic>.from(
              jsonDecode(chunk.substring('data: '.length)) as Map,
            ),
    ];
    final deltas =
        frames.where((f) => f['object'] == 'chat.completion.chunk').toList();
    expect(deltas.length, 3);
    final firstDelta = deltas.first['choices'][0]['delta'] as Map;
    expect(firstDelta['role'], 'assistant');
    expect(firstDelta['content'], 'Halo, ');
    expect(raw.contains('[DONE]'), isTrue);
    final finish = deltas.last['choices'][0] as Map;
    expect(finish['finish_reason'], 'stop');
    expect(deltas.last['usage']['total_tokens_reported'], 421);
    final joined = [
      for (final d in deltas) (d['choices'][0]['delta'] as Map)['content'] ?? '',
    ].join();
    expect(joined, 'Halo, ini jawaban $finger');
  });

  test('tanpa stream: JSON lengkap dengan total_tokens_reported', () async {
    final (res, raw) = await post({
      'messages': [
        {'role': 'user', 'content': 'sapa'},
      ],
    });
    expect(res.headers.contentType?.mimeType, 'application/json');
    final body = jsonDecode(raw) as Map;
    expect(body['usage']['total_tokens_reported'], 421);
  });

  test('fallback: hanya onMessage (tanpa progress) tetap satu potong',
      () async {
    final fallback = HttpApiServer(
      onMessage: (msg) async => 'jawaban tunggal $finger',
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await fallback.start();
    try {
      final client = HttpClient();
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${fallback.boundPort}/v1/chat/completions'),
      );
      req.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({
        'messages': [
          {'role': 'user', 'content': 'sapa'},
        ],
        'stream': true,
      })));
      final res = await req.close();
      final raw = await res.transform(utf8.decoder).join();
      final contentChunks = RegExp('"content":"([^"]*)"')
          .allMatches(raw)
          .map((m) => m.group(1))
          .toList();
      expect(contentChunks.join(), 'jawaban tunggal $finger');
      client.close(force: true);
    } finally {
      await fallback.stop();
    }
  });

  // S20-C: frame chat.usage dengan prompt/completion terpisah terus
  // terpropagasi ke usage JSON (prompt_tokens_reported/completion_tokens_reported).
  test('chat.usage split: prompt_tokens_reported + completion_tokens_reported',
      () async {
    final split = HttpApiServer(
      onMessage: (msg) async => 'ok',
      onMessageWithProgress: (msg, progress) async {
        progress({'type': 'chat.usage', 'tokens': 421,
            'prompt': 390, 'completion': 31});
        return 'ok';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await split.start();
    try {
      final client = HttpClient();
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${split.boundPort}/v1/chat/completions'),
      );
      req.headers
          .set('authorization', 'Bearer manager-token-0123456789abcdef');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({
        'messages': [
          {'role': 'user', 'content': 'sapa'},
        ],
      })));
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['usage']['total_tokens_reported'], 421);
      expect(body['usage']['prompt_tokens_reported'], 390);
      expect(body['usage']['completion_tokens_reported'], 31);
      client.close(force: true);
    } finally {
      await split.stop();
    }
  });
}
