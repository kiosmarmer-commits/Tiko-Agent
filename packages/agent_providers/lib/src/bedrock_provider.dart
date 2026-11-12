import 'dart:typed_data';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

/// AWS Bedrock Converse adapter (Hermes-parity `bedrock` provider).
///
/// Requests are signed with AWS Signature V4 (pure Dart via package:crypto)
/// against `https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/
/// converse`. Streaming is intentionally unsupported (non-streaming only);
/// tool calling uses the Converse `toolUse`/`toolResult` content blocks.
class BedrockProvider implements LlmProvider {
  BedrockProvider({
    required this.id,
    required this.region,
    required this.model,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
    this.endpoint,
    this.httpClient,
    this.requestTimeout,
    Capabilities? capabilities,
  }) : capabilities = capabilities ??
            const Capabilities(
              toolCalling: true,
              streaming: false,
              maxContext: 200000,
            );

  @override
  final String id;
  final String region;
  final String model;
  final String accessKeyId;
  final String secretAccessKey;

  /// Optional temporary credentials (STS) token.
  final String? sessionToken;

  /// Override for tests / VPC endpoints; default derives from [region].
  final String? endpoint;
  final http.Client? httpClient;
  final Duration? requestTimeout;

  @override
  final Capabilities capabilities;

  @override
  Future<List<double>> embed(String text) async => const [];

  Uri get converseUri {
    final host = endpoint ?? 'bedrock-runtime.$region.amazonaws.com';
    final encoded = Uri.encodeComponent(model);
    return Uri.parse('https://$host/model/$encoded/converse');
  }

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final body = _buildBody(req);
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            converseUri,
            headers: _signedHeaders(body),
            body: jsonEncode(body),
          )
          .timeout(requestTimeout ?? const Duration(hours: 1));
      if (response.statusCode >= 400) {
        yield LlmError(
          'HTTP ${response.statusCode}: ${response.body}',
          code: '${response.statusCode}',
        );
        return;
      }
      yield* _parseConverse(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      yield LlmError(e.toString());
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Map<String, dynamic> _buildBody(ChatRequest req) {
    String? system;
    final messages = <Map<String, dynamic>>[];
    for (final m in req.messages) {
      if (m.role == 'system') {
        system = (system == null) ? m.content : '$system\n${m.content}';
        continue;
      }
      if (m.role == 'assistant' && m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        messages.add({
          'role': 'assistant',
          'content': [
            for (final c in m.toolCalls!)
              {
                'toolUse': {
                  'toolUseId': c.id,
                  'name': c.name,
                  'input': c.args,
                },
              },
          ],
        });
        continue;
      }
      if (m.role == 'tool') {
        messages.add({
          'role': 'user',
          'content': [
            {
              'toolResult': {
                'toolUseId': m.toolCallId ?? '',
                'content': [
                  {'text': m.content},
                ],
              },
            },
          ],
        });
        continue;
      }
      messages.add({
        'role': m.role == 'assistant' ? 'assistant' : 'user',
        'content': [
          {'text': m.content},
        ],
      });
    }
    return {
      if (system != null)
        'system': [
          {'text': system},
        ],
      'messages': messages,
      if (req.maxTokens != null || req.temperature != null)
        'inferenceConfig': {
          if (req.maxTokens != null) 'maxTokens': req.maxTokens,
          if (req.temperature != null) 'temperature': req.temperature,
        },
      if (req.tools.isNotEmpty)
        'toolConfig': {
          'tools': [
            for (final t in req.tools)
              {
                'toolSpec': {
                  'name': t.name,
                  'description': t.description,
                  'inputSchema': {'json': t.inputSchema},
                },
              },
          ],
        },
    };
  }

  Stream<LlmEvent> _parseConverse(Map<String, dynamic> json) async* {
    final output = json['output'] as Map<String, dynamic>?;
    final message = output?['message'] as Map<String, dynamic>?;
    final content = message?['content'] as List<dynamic>? ?? const [];
    for (final raw in content) {
      final block = raw as Map<String, dynamic>;
      final text = block['text'] as String?;
      if (text != null && text.isNotEmpty) yield LlmTextDelta(text);
      final toolUse = block['toolUse'] as Map<String, dynamic>?;
      if (toolUse != null) {
        yield LlmToolCall(
          ToolCall(
            id: toolUse['toolUseId'] as String? ?? '',
            name: toolUse['name'] as String? ?? '',
            args:
                (toolUse['input'] as Map<String, dynamic>?) ??
                const <String, dynamic>{},
          ),
        );
      }
    }
    final u = json['usage'] as Map<String, dynamic>?;
    if (u != null) {
      yield LlmUsage(
        TokenUsage(
          prompt: (u['inputTokens'] as num?)?.toInt() ?? 0,
          completion: (u['outputTokens'] as num?)?.toInt() ?? 0,
          total: (u['totalTokens'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    yield LlmDone(finishReason: json['stopReason'] as String? ?? 'stop');
  }

  Map<String, String> _signedHeaders(Map<String, dynamic> body) {
    final now = DateTime.now().toUtc();
    final amzDate =
        '${now.year}${_pad(now.month)}${_pad(now.day)}T'
        '${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}Z';
    return awsSigV4Headers(
      method: 'POST',
      uri: converseUri,
      payload: jsonEncode(body),
      contentType: 'application/json',
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken,
      region: region,
      service: 'bedrock',
      amzDate: amzDate,
    );
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

/// Pure AWS Signature V4 signer (testable against fixed timestamps).
Map<String, String> awsSigV4Headers({
  required String method,
  required Uri uri,
  required String payload,
  required String contentType,
  required String accessKeyId,
  required String secretAccessKey,
  String? sessionToken,
  required String region,
  required String service,
  required String amzDate,
}) {
  final dateStamp = amzDate.substring(0, 8);
  final headers = <String, String>{
    'content-type': contentType,
    'host': uri.host,
    'x-amz-date': amzDate,
    if (sessionToken != null && sessionToken.isNotEmpty)
      'x-amz-security-token': sessionToken,
  };
  final signedHeaderKeys = headers.keys.toList()..sort();
  final canonicalHeaders =
      signedHeaderKeys.map((k) => '$k:${headers[k]}\n').join();
  final signedHeaders = signedHeaderKeys.join(';');

  final canonicalRequest = [
    method,
    uri.path,
    '',
    canonicalHeaders,
    signedHeaders,
    crypto.sha256.convert(utf8.encode(payload)),
  ].join('\n');

  final scope = '$dateStamp/$region/$service/aws4_request';
  final stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    crypto.sha256.convert(utf8.encode(canonicalRequest)),
  ].join('\n');

  var signingKey = Uint8List.fromList(utf8.encode('AWS4$secretAccessKey'));
  for (final part in [dateStamp, region, service, 'aws4_request']) {
    signingKey = Uint8List.fromList(
      crypto
          .Hmac(crypto.sha256, signingKey)
          .convert(utf8.encode(part))
          .bytes,
    );
  }
  final signature = crypto.Hmac(crypto.sha256, signingKey)
      .convert(utf8.encode(stringToSign))
      .toString();

  return {
    ...headers,
    'Authorization':
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope, '
        'SignedHeaders=$signedHeaders, Signature=$signature',
  };
}
