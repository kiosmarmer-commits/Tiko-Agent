import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

/// Hermes-P5: progress live untuk POST `/v1/messages` via Server-Sent
/// Events — frame progress sama dengan WS `/v1/stream` (chat.status,
/// chat.tool, chat.delta) diikuti `text` jawaban final dan `done`. Klien
/// tanpa stream tetap menerima JSON sinkron dari jalur lama.
void main() {
  late HttpApiServer server;

  setUp(() async {
    server = HttpApiServer(
      onMessage: (msg) async => 'balasan: ${msg.text}',
      onMessageWithProgress: (msg, progress) async {
        progress({'type': 'chat.status', 'state': 'running'});
        progress({'type': 'chat.toolStart', 'name': 'read_file'});
        progress({'type': 'chat.delta', 'text': 'Halo, '});
        progress({'type': 'chat.delta', 'text': 'ini jawaban'});
        progress({
          'type': 'chat.tool',
          'name': 'read_file',
          'is_error': false,
          'duration_ms': 12,
        });
        progress({'type': 'chat.status', 'state': 'done'});
        return 'Halo, ini jawaban';
      },
      authToken: 'manager-token-0123456789abcdef',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  test('/v1/messages stream=true mengalirkan frame SSE lalu text+done',
      () async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/messages'),
      );
      req.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(
        jsonEncode({'text': 'sapa', 'session_key': 'http:t1', 'stream': true}),
      ));
      final res = await req.close();
      expect(res.headers.contentType?.mimeType, 'text/event-stream');
      final raw = await res.transform(utf8.decoder).join();
      final frames = <Map<String, dynamic>>[
        for (final chunk in raw.split('\n\n'))
          if (chunk.startsWith('data: '))
            Map<String, dynamic>.from(
              jsonDecode(chunk.substring('data: '.length)) as Map,
            ),
      ];
      final types = [for (final f in frames) f['type'] as String];
      expect(types.first, 'chat.status');
      expect(types, contains('chat.toolStart'));
      expect(types.where((t) => t == 'chat.delta'), hasLength(2));
      expect(types, contains('chat.tool'));
      expect(types.last, 'done');
      final textFrame = frames.firstWhere((f) => f['type'] == 'text');
      expect(textFrame['text'], 'Halo, ini jawaban');
    } finally {
      client.close(force: true);
    }
  });

  test('/v1/messages tanpa stream tetap JSON sinkron', () async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/messages'),
      );
      req.headers.set('authorization', 'Bearer manager-token-0123456789abcdef');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode({'text': 'sapa'})));
      final res = await req.close();
      expect(res.headers.contentType?.mimeType, 'application/json');
      final body =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['text'], 'balasan: sapa');
    } finally {
      client.close(force: true);
    }
  });
}
