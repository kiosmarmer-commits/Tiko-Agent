import 'dart:convert';

import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:agent_core/agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('provider presets (Hermes-parity catalog)', () {
    test('preset utama tersedia', () {
      expect(findProviderPreset('openrouter'), isNotNull);
      expect(findProviderPreset('deepseek'), isNotNull);
      expect(findProviderPreset('groq'), isNotNull);
      expect(findProviderPreset('kimi-cn'), isNotNull); // dash -> underscore
      expect(findProviderPreset('OpenRouter'), isNotNull); // case-insensitive
      expect(findProviderPreset('ollama_cloud'), isNotNull);
      expect(findProviderPreset('openai_codex'), isNotNull);
      expect(findProviderPreset('openai_codex')!.transport, 'responses');
      expect(findProviderPreset('azure')!.transport, 'azure');
      expect(findProviderPreset('bedrock')!.transport, 'bedrock');
      expect(findProviderPreset('anthropic')!.transport, 'anthropic_messages');
    });

    test('preset tidak dikenal -> null', () {
      expect(findProviderPreset('nonexistent'), isNull);
      expect(findProviderPreset(''), isNull);
    });

    test('catalog mencakup 30+ preset', () {
      expect(providerPresets.length, greaterThanOrEqualTo(30));
    });
  });

  group('CredentialPool', () {
    test('rotasi round-robin pada kegagalan', () {
      final pool = CredentialPool(['k1', 'k2', 'k3']);
      expect(pool.current, 'k1');
      expect(pool.reportFailure(), 'k2');
      expect(pool.reportFailure(), 'k3');
      expect(pool.reportFailure(), 'k1');
      expect(pool.rotations, 3);
    });

    test('key kosong ditolak', () {
      expect(() => CredentialPool(['', '  ']), throwsArgumentError);
      expect(() => CredentialPool(const []), throwsArgumentError);
    });

    test('OpenAiCompatProvider rotasi saat 401 lalu sukses', () async {
      var requests = 0;
      final provider = OpenAiCompatProvider(
        id: 'p',
        baseUrl: 'http://localhost:1/v1',
        model: 'm',
        credentialPool: CredentialPool(['bad', 'good']),
        httpClient: _FakeClient((req) async {
          requests++;
          final auth = req.headers['Authorization'];
          if (auth == 'Bearer bad') {
            return http.Response('{"error":"unauthorized"}', 401);
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final events = await provider
          .chat(ChatRequest(
        messages: [ChatMessage(role: 'user', content: 'halo')],
        stream: false,
      ))
          .toList();

      expect(requests, 2);
      expect(events.whereType<LlmTextDelta>().isNotEmpty, isTrue);
      expect(events.whereType<LlmError>(), isEmpty);
    });
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);
  final Future<http.Response> Function(http.Request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request as http.Request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}
