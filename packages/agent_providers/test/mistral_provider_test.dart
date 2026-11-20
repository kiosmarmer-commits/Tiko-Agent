import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Map<String, dynamic> requestBody;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"Halo"}}]}\n\n',
      );
      request.response.write(
        'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test(
    'stream mengembalikan usage Mistral dan meminta include_usage',
    () async {
      final provider = MistralProvider(
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final events = await provider
          .chat(
            const ChatRequest(
              messages: [ChatMessage(role: 'user', content: 'halo')],
            ),
          )
          .toList();

      expect(
        events.whereType<LlmTextDelta>().map((e) => e.delta).join(),
        'Halo',
      );
      expect(events.whereType<LlmUsage>().single.usage.total, 16);
      expect(requestBody['stream_options'], {'include_usage': true});
    },
  );
}
