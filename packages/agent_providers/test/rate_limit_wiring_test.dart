import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _rateHeaders = {
  'x-ratelimit-limit-requests': '100',
  'x-ratelimit-remaining-requests': '80',
  'x-ratelimit-reset-requests': '12.5',
  'x-ratelimit-limit-tokens-1h': '10000',
  'x-ratelimit-remaining-tokens-1h': '7500',
  'X-RateLimit-Reset-Tokens-1h': '600',
};

void main() {
  group('OpenAiCompatProvider rate-limit capture', () {
    test('non-stream: header x-ratelimit-* dicatat ke tracker', () async {
      final tracker = RateLimitTracker();
      final provider = OpenAiCompatProvider(
        id: 'p1',
        baseUrl: 'http://127.0.0.1:9/v1',
        model: 'm',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'},
                  },
                ],
              }),
              200,
              headers: _rateHeaders,
            )),
        rateLimitTracker: tracker,
      );
      final out = await provider
          .chat(ChatRequest(
            messages: const [ChatMessage(role: 'user', content: 'hai')],
            stream: false,
          ))
          .toList();
      expect(out.whereType<LlmTextDelta>(), isNotEmpty);
      final s = tracker.stateFor('p1');
      expect(s, isNotNull);
      expect(s!.requestsMin.limit, 100);
      expect(s.requestsMin.remaining, 80);
      expect(s.requestsMin.used, 20);
      expect(s.tokensHour.limit, 10000);
      expect(s.tokensHour.remaining, 7500);
    });

    test('stream: header dari streamed response dicatat', () async {
      final tracker = RateLimitTracker();
      final sse = 'data: {"choices": [{"delta": {"content": "halo"}}]}\n\n'
          'data: [DONE]\n\n';
      final provider = OpenAiCompatProvider(
        id: 'p2',
        baseUrl: 'http://127.0.0.1:9/v1',
        model: 'm',
        httpClient: MockClient.streaming((req, body) async =>
            http.StreamedResponse(
              Stream.value(utf8.encode(sse)),
              200,
              headers: _rateHeaders,
            )),
        rateLimitTracker: tracker,
      );
      await provider
          .chat(ChatRequest(
            messages: const [ChatMessage(role: 'user', content: 'hai')],
            stream: true,
          ))
          .toList();
      final s = tracker.stateFor('p2');
      expect(s, isNotNull);
      expect(s!.requestsMin.used, 20);
    });

    test('tanpa tracker → turn tetap jalan (fail-open)', () async {
      final provider = OpenAiCompatProvider(
        id: 'p3',
        baseUrl: 'http://127.0.0.1:9/v1',
        model: 'm',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'},
                  },
                ],
              }),
              200,
              headers: _rateHeaders,
            )),
      );
      final out = await provider
          .chat(ChatRequest(messages: const [ChatMessage(role: 'user', content: 'hai')], stream: false))
          .toList();
      expect(out.whereType<LlmTextDelta>(), isNotEmpty);
    });

    test('respons tanpa header rate-limit → state tidak dicatat', () async {
      final tracker = RateLimitTracker();
      final provider = OpenAiCompatProvider(
        id: 'p4',
        baseUrl: 'http://127.0.0.1:9/v1',
        model: 'm',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'},
                  },
                ],
              }),
              200,
            )),
        rateLimitTracker: tracker,
      );
      await provider
          .chat(ChatRequest(messages: const [ChatMessage(role: 'user', content: 'hai')], stream: false))
          .toList();
      expect(tracker.stateFor('p4')?.hasData ?? false, isFalse);
    });
  });

  group('AnthropicProvider rate-limit capture', () {
    test('header respons dicatat ke tracker', () async {
      final tracker = RateLimitTracker();
      final provider = AnthropicProvider(
        apiKey: 'k',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': 'ok'},
                ],
                'usage': {'input_tokens': 1, 'output_tokens': 1},
              }),
              200,
              headers: _rateHeaders,
            )),
        rateLimitTracker: tracker,
      );
      await provider
          .chat(ChatRequest(messages: const [ChatMessage(role: 'user', content: 'hai')]))
          .toList();
      final s = tracker.stateFor('anthropic');
      expect(s, isNotNull);
      expect(s!.requestsMin.limit, 100);
    });
  });

  group('GeminiProvider rate-limit capture', () {
    test('header respons dicatat ke tracker', () async {
      final tracker = RateLimitTracker();
      final provider = GeminiProvider(
        apiKey: 'k',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'ok'},
                      ],
                    },
                  },
                ],
              }),
              200,
              headers: _rateHeaders,
            )),
        rateLimitTracker: tracker,
      );
      await provider
          .chat(ChatRequest(messages: const [ChatMessage(role: 'user', content: 'hai')]))
          .toList();
      final s = tracker.stateFor('gemini');
      expect(s, isNotNull);
      expect(s!.tokensHour.used, 2500);
    });
  });

  group('OpenRouterProvider rate-limit capture', () {
    test('header respons SSE dicatat ke tracker', () async {
      final tracker = RateLimitTracker();
      final provider = OpenRouterProvider(
        apiKey: 'k',
        httpClient: MockClient((req) async => http.Response(
              'data: {"choices": [{"delta": {"content": "halo"}}]}\n\n'
              'data: [DONE]\n\n',
              200,
              headers: _rateHeaders,
            )),
        rateLimitTracker: tracker,
      );
      await provider
          .chat(ChatRequest(messages: const [ChatMessage(role: 'user', content: 'hai')]))
          .toList();
      final s = tracker.stateFor('openrouter');
      expect(s, isNotNull);
      expect(s!.requestsMin.used, 20);
    });
  });
}
