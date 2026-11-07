import 'dart:convert';
import 'dart:io';

import 'package:agent_gateway/agent_gateway.dart';
import 'package:test/test.dart';

void main() {
  late HttpApiServer server;
  var calls = 0;

  setUp(() async {
    calls = 0;
    server = HttpApiServer(
      onMessage: (message) async {
        calls++;
        return 'jawaban-${message.text}';
      },
      authToken: 'test-token',
      host: '127.0.0.1',
      port: 0,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, Object?>> post(String idempotencyKey) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}/v1/messages'),
      );
      req.headers.set('Authorization', 'Bearer test-token');
      if (idempotencyKey.isNotEmpty) {
        req.headers.set('Idempotency-Key', idempotencyKey);
      }
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'text': 'halo',
        'session_key': 'idem-test',
        'user_key': 'tester',
      }));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return {
        'status': res.statusCode,
        'body': body,
        'replayed': res.headers.value('Idempotency-Replayed'),
      };
    } finally {
      client.close(force: true);
    }
  }

  test('replays the first response for a repeated key', () async {
    final first = await post('key-1');
    final second = await post('key-1');
    expect(calls, 1);
    expect(first['status'], 200);
    expect(second['status'], 200);
    expect(second['replayed'], 'true');
    final firstJson =
        jsonDecode(first['body'] as String) as Map<String, dynamic>;
    final secondJson =
        jsonDecode(second['body'] as String) as Map<String, dynamic>;
    expect(secondJson['text'], firstJson['text']);
    expect(secondJson['idempotent_replay'], isTrue);
    expect(firstJson.containsKey('idempotent_replay'), isFalse);
  });

  test('without a key every request runs the handler', () async {
    await post('');
    await post('');
    expect(calls, 2);
  });

  test('different keys run independently', () async {
    await post('key-a');
    await post('key-b');
    expect(calls, 2);
  });
}
