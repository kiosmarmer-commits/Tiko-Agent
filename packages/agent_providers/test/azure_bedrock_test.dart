import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

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

void main() {
  group('AzureOpenAIProvider', () {
    test('URL deployment + api-version + header api-key', () async {
      final captured = <http.Request>[];
      final provider = AzureOpenAIProvider(
        id: 'azure',
        baseUrl: 'https://my-res.openai.azure.com',
        model: 'gpt-4o-deploy',
        apiKey: 'azure-key-1',
        apiVersion: '2024-10-21',
        httpClient: _FakeClient((req) async {
          captured.add(req);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'halo azure'},
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
            messages: [ChatMessage(role: 'user', content: 'hai')],
            stream: false,
          ))
          .toList();

      final req = captured.single;
      expect(req.url.host, 'my-res.openai.azure.com');
      expect(req.url.path, '/openai/deployments/gpt-4o-deploy/chat/completions');
      expect(req.url.queryParameters['api-version'], '2024-10-21');
      expect(req.headers['api-key'], 'azure-key-1');
      expect(req.headers.containsKey('Authorization'), isFalse);
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.delta).join(),
        'halo azure',
      );
    });
  });

  group('BedrockProvider', () {
    test('SigV4 cocok dengan implementasi referensi (vector)', () {
      final headers = awsSigV4Headers(
        method: 'POST',
        uri: Uri.parse(
          'https://bedrock-runtime.us-east-1.amazonaws.com'
          '/model/anthropic.claude-sonnet-4-20250514-v1%3A0/converse',
        ),
        payload: '{"messages":[{"role":"user","content":[{"text":"halo"}]}]}',
        contentType: 'application/json',
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
        service: 'bedrock',
        amzDate: '20261112T000000Z',
      );

      expect(headers['x-amz-date'], '20261112T000000Z');
      expect(headers['host'], 'bedrock-runtime.us-east-1.amazonaws.com');
      final auth = headers['Authorization']!;
      expect(auth, startsWith('AWS4-HMAC-SHA256 '));
      expect(auth, contains('Credential=AKIDEXAMPLE/20261112/us-east-1/bedrock/aws4_request'));
      expect(
        auth,
        contains('SignedHeaders=content-type;host;x-amz-date'),
      );
      expect(
        auth,
        contains('Signature=a17c51c7148175248cbc69f19649466d40371e2b4de34cbf7c9105c98911ec71'),
      );
    });

    test('session token masuk signed headers', () {
      final headers = awsSigV4Headers(
        method: 'POST',
        uri: Uri.parse('https://bedrock-runtime.us-east-1.amazonaws.com/m/converse'),
        payload: '{}',
        contentType: 'application/json',
        accessKeyId: 'AKID',
        secretAccessKey: 'SECRET',
        sessionToken: 'STS-TOKEN',
        region: 'us-east-1',
        service: 'bedrock',
        amzDate: '20261112T000000Z',
      );
      expect(headers['x-amz-security-token'], 'STS-TOKEN');
      expect(
        headers['Authorization'],
        contains('SignedHeaders=content-type;host;x-amz-date;x-amz-security-token'),
      );
    });

    test('Converse: parse teks + toolUse + usage', () async {
      final captured = <http.Request>[];
      final provider = BedrockProvider(
        id: 'bedrock',
        region: 'us-east-1',
        model: 'anthropic.claude-sonnet-4-20250514-v1:0',
        accessKeyId: 'AKID',
        secretAccessKey: 'SECRET',
        httpClient: _FakeClient((req) async {
          captured.add(req);
          return http.Response(
            jsonEncode({
              'output': {
                'message': {
                  'role': 'assistant',
                  'content': [
                    {'text': 'jawaban bedrock'},
                    {
                      'toolUse': {
                        'toolUseId': 'tu_1',
                        'name': 'calc',
                        'input': {'expression': '2+2'},
                      },
                    },
                  ],
                },
              },
              'usage': {'inputTokens': 11, 'outputTokens': 4, 'totalTokens': 15},
              'stopReason': 'tool_use',
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

      final req = captured.single;
      expect(req.url.host, 'bedrock-runtime.us-east-1.amazonaws.com');
      expect(req.url.path, '/model/anthropic.claude-sonnet-4-20250514-v1%3A0/converse');
      expect(req.headers['Authorization'], startsWith('AWS4-HMAC-SHA256'));
      expect(req.headers.containsKey('x-amz-security-token'), isFalse);

      expect(
        events.whereType<LlmTextDelta>().map((e) => e.delta).join(),
        'jawaban bedrock',
      );
      final call = events.whereType<LlmToolCall>().single.call;
      expect(call.id, 'tu_1');
      expect(call.name, 'calc');
      expect(call.args['expression'], '2+2');
      expect(events.whereType<LlmUsage>().first.usage.total, 15);
      expect(events.whereType<LlmDone>().first.finishReason, 'tool_use');
      expect(provider.capabilities.streaming, isFalse);
    });

    test('mapping: system/tool result jadi blok Converse yang benar', () async {
      final captured = <http.Request>[];
      final provider = BedrockProvider(
        id: 'bedrock',
        region: 'us-west-2',
        model: 'm',
        accessKeyId: 'AKID',
        secretAccessKey: 'SECRET',
        httpClient: _FakeClient((req) async {
          captured.add(req);
          return http.Response(
            jsonEncode({
              'output': {
                'message': {
                  'role': 'assistant',
                  'content': [
                    {'text': 'ok'},
                  ],
                },
              },
            }),
            200,
          );
        }),
      );

      await provider
          .chat(ChatRequest(
            messages: [
              ChatMessage(role: 'system', content: 'Kamu agent.'),
              ChatMessage(role: 'user', content: 'hitung'),
              ChatMessage(
                role: 'assistant',
                content: '',
                toolCalls: [
                  ToolCall(id: 'tu_1', name: 'calc', args: {'expression': '1+1'}),
                ],
              ),
              ChatMessage(role: 'tool', content: '2', toolCallId: 'tu_1'),
            ],
            stream: false,
          ))
          .toList();

      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect((body['system'] as List).first['text'], 'Kamu agent.');
      final messages = body['messages'] as List;
      expect(messages[0]['role'], 'user');
      expect(messages[1]['role'], 'assistant');
      expect(
        (messages[1]['content'] as List).first['toolUse']['name'],
        'calc',
      );
      expect(messages[2]['role'], 'user');
      expect(
        (messages[2]['content'] as List).first['toolResult']['toolUseId'],
        'tu_1',
      );
    });
  });
}
