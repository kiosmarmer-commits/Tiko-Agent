import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'openai_compat.dart';

/// OpenAI **Responses API** adapter (`POST {base}/responses`) — Hermes-parity
/// transport `codex_responses` used by openai-codex and newer OpenAI models.
/// Supports streaming SSE events, function tool calls, and usage reporting.
class OpenAiResponsesProvider extends OpenAiCompatProvider {
  OpenAiResponsesProvider({
    required super.id,
    required super.baseUrl,
    required super.model,
    super.apiKey,
    super.httpClient,
    super.promptCache,
    super.credentialPool,
    super.tokenProvider,
    super.requestTimeout,
    super.modelTimeouts,
    super.capabilities,
  });

  Uri get _responsesUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/responses');
  }

  /// Maps the internal chat messages to Responses `input` items. The first
  /// system message becomes top-level `instructions`; tool results become
  /// `function_call_output` items paired by call id.
  (String?, List<Map<String, dynamic>>) _buildInput(List<ChatMessage> msgs) {
    String? instructions;
    final input = <Map<String, dynamic>>[];
    for (final m in msgs) {
      switch (m.role) {
        case 'system':
          instructions = (instructions == null)
              ? m.content
              : '$instructions\n${m.content}';
        case 'user':
          input.add({
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': m.content},
            ],
          });
        case 'assistant':
          if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
            for (final c in m.toolCalls!) {
              input.add({
                'type': 'function_call',
                'call_id': c.id,
                'name': c.name,
                'arguments': jsonEncode(c.args),
              });
            }
          } else {
            input.add({
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': m.content},
              ],
            });
          }
        case 'tool':
          input.add({
            'type': 'function_call_output',
            'call_id': m.toolCallId ?? '',
            'output': m.content,
          });
      }
    }
    return (instructions, input);
  }

  Map<String, dynamic> _buildBody(ChatRequest req) {
    final (instructions, input) = _buildInput(req.messages);
    return {
      'model': req.model ?? model,
      'stream': req.stream,
      if (instructions != null) 'instructions': instructions,
      'input': input,
      if (req.maxTokens != null) 'max_output_tokens': req.maxTokens,
      if (req.temperature != null) 'temperature': req.temperature,
      if (req.tools.isNotEmpty)
        'tools': req.tools
            .map(
              (t) => {
                'type': 'function',
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            )
            .toList(),
      if (req.toolChoice != null) 'tool_choice': req.toolChoice,
    };
  }

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final key = await resolveKey();
    final headers = await headersFor(key);
    final body = _buildBody(req);
    final client = httpClient ?? http.Client();
    try {
      if (req.stream) {
        yield* _stream(client, body, headers);
      } else {
        yield* _nonStream(client, body, headers);
      }
    } catch (e) {
      yield LlmError(e.toString());
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Stream<LlmEvent> _stream(
    http.Client client,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async* {
    final request = http.Request('POST', _responsesUri)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);
    final response = await client
        .send(request)
        .timeout(requestTimeout ?? const Duration(hours: 1));
    if (response.statusCode >= 400) {
      final err = await response.stream.bytesToString();
      yield LlmError(
        'HTTP ${response.statusCode}: $err',
        code: '${response.statusCode}',
      );
      return;
    }

    final argBuf = <String, StringBuffer>{};

    await for (final chunk
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final line = chunk.trim();
      if (line.isEmpty || !line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final type = json['type'] as String? ?? '';

      switch (type) {
        case 'response.output_text.delta':
          final delta = json['delta'] as String?;
          if (delta != null && delta.isNotEmpty) yield LlmTextDelta(delta);
        case 'response.function_call_arguments.delta':
          final id = json['item_id'] as String? ?? 'call_0';
          (argBuf[id] ??= StringBuffer()).write(json['delta'] as String? ?? '');
        case 'response.output_item.done':
          final item = json['item'] as Map<String, dynamic>?;
          if (item != null && item['type'] == 'function_call') {
            final id = item['id'] as String? ?? 'call_0';
            final rawArgs =
                (item['arguments'] as String?) ?? argBuf[id]?.toString() ?? '';
            Map<String, dynamic> args;
            try {
              args = jsonDecode(rawArgs) as Map<String, dynamic>;
            } catch (_) {
              args = {'_raw': rawArgs};
            }
            yield LlmToolCall(
              ToolCall(
                id: item['call_id'] as String? ?? id,
                name: item['name'] as String? ?? '',
                args: args,
              ),
            );
          }
        case 'response.completed':
          final resp = json['response'] as Map<String, dynamic>?;
          final u = resp?['usage'] as Map<String, dynamic>?;
          if (u != null) {
            yield LlmUsage(
              TokenUsage(
                prompt: (u['input_tokens'] as num?)?.toInt() ?? 0,
                completion: (u['output_tokens'] as num?)?.toInt() ?? 0,
                total: (u['total_tokens'] as num?)?.toInt() ?? 0,
              ),
            );
          }
          yield const LlmDone();
          return;
        case 'response.failed':
        case 'error':
          yield LlmError(
            json['message'] as String? ?? 'responses stream gagal',
          );
          return;
      }
    }
    yield const LlmDone();
  }

  Stream<LlmEvent> _nonStream(
    http.Client client,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async* {
    final response = await client
        .post(_responsesUri, headers: headers, body: jsonEncode(body))
        .timeout(requestTimeout ?? const Duration(hours: 1));
    if (response.statusCode >= 400) {
      yield LlmError(
        'HTTP ${response.statusCode}: ${response.body}',
        code: '${response.statusCode}',
      );
      return;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final output = json['output'] as List<dynamic>? ?? const [];

    for (final raw in output) {
      final item = raw as Map<String, dynamic>;
      if (item['type'] == 'message') {
        final content = item['content'] as List<dynamic>? ?? const [];
        for (final c in content) {
          if (c is Map && c['type'] == 'output_text') {
            final text = c['text'] as String?;
            if (text != null && text.isNotEmpty) yield LlmTextDelta(text);
          }
        }
      } else if (item['type'] == 'function_call') {
        final rawArgs = item['arguments'] as String?;
        Map<String, dynamic> args;
        try {
          args = rawArgs == null
              ? <String, dynamic>{}
              : jsonDecode(rawArgs) as Map<String, dynamic>;
        } catch (_) {
          args = {'_raw': rawArgs ?? ''};
        }
        yield LlmToolCall(
          ToolCall(
            id: item['call_id'] as String? ?? item['id'] as String? ?? '',
            name: item['name'] as String? ?? '',
            args: args,
          ),
        );
      }
    }

    final u = json['usage'] as Map<String, dynamic>?;
    if (u != null) {
      yield LlmUsage(
        TokenUsage(
          prompt: (u['input_tokens'] as num?)?.toInt() ?? 0,
          completion: (u['output_tokens'] as num?)?.toInt() ?? 0,
          total: (u['total_tokens'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    yield LlmDone(finishReason: json['status'] as String? ?? 'completed');
  }
}
