import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Thin OpenAI-compatible chat provider (Ollama /v1, LM Studio, OpenRouter, Groq, …).
/// TASK-02-01: streaming + tool calling.
class OpenAiCompatProvider implements LlmProvider {
  OpenAiCompatProvider({
    required this.id,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.httpClient,
    Capabilities? capabilities,
  }) : capabilities =
           capabilities ??
           const Capabilities(
             toolCalling: true,
             streaming: true,
             maxContext: 32768,
           );

  @override
  final String id;
  final String baseUrl; // e.g. http://127.0.0.1:11434/v1
  final String model;
  final String? apiKey;
  final http.Client? httpClient;

  @override
  final Capabilities capabilities;

  Uri get _chatUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final body = <String, dynamic>{
      'model': req.model ?? model,
      'messages': req.messages.map((m) => m.toJson()).toList(),
      'stream': req.stream,
      if (req.maxTokens != null) 'max_tokens': req.maxTokens,
      if (req.temperature != null) 'temperature': req.temperature,
      if (req.tools.isNotEmpty)
        'tools': req.tools
            .map(
              (t) => {
                'type': 'function',
                'function': {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.inputSchema,
                },
              },
            )
            .toList(),
      if (req.toolChoice != null) 'tool_choice': req.toolChoice,
    };

    final client = httpClient ?? http.Client();
    try {
      if (req.stream) {
        yield* _streamChat(client, body);
      } else {
        yield* _nonStreamChat(client, body);
      }
    } catch (e) {
      yield LlmError(e.toString());
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Stream<LlmEvent> _streamChat(
    http.Client client,
    Map<String, dynamic> body,
  ) async* {
    final request = http.Request('POST', _chatUri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);

    final response = await client.send(request);
    if (response.statusCode >= 400) {
      final err = await response.stream.bytesToString();
      yield LlmError(
        'HTTP ${response.statusCode}: $err',
        code: '${response.statusCode}',
      );
      return;
    }

    final toolCallsAcc = <int, _PartialToolCall>{};
    var usage = const TokenUsage();

    await for (final chunk
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final line = chunk.trim();
      if (line.isEmpty || !line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') {
        // Flush any complete tool calls.
        for (final p in toolCallsAcc.values) {
          if (p.name != null && p.arguments.isNotEmpty) {
            try {
              final args = jsonDecode(p.arguments) as Map<String, dynamic>;
              yield LlmToolCall(
                ToolCall(
                  id: p.id ?? 'call_${p.index}',
                  name: p.name!,
                  args: args,
                ),
              );
            } catch (_) {
              yield LlmToolCall(
                ToolCall(
                  id: p.id ?? 'call_${p.index}',
                  name: p.name!,
                  args: {'_raw': p.arguments},
                ),
              );
            }
          }
        }
        if (usage.total > 0) yield LlmUsage(usage);
        yield const LlmDone();
        return;
      }

      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) continue;
        final delta =
            (choices.first as Map<String, dynamic>)['delta']
                as Map<String, dynamic>? ??
            {};

        final content = delta['content'] as String?;
        if (content != null && content.isNotEmpty) {
          yield LlmTextDelta(content);
        }

        final tcs = delta['tool_calls'] as List<dynamic>?;
        if (tcs != null) {
          for (final raw in tcs) {
            final tc = raw as Map<String, dynamic>;
            final idx = tc['index'] as int? ?? 0;
            final partial = toolCallsAcc.putIfAbsent(
              idx,
              () => _PartialToolCall(idx),
            );
            if (tc['id'] != null) partial.id = tc['id'] as String;
            final fn = tc['function'] as Map<String, dynamic>?;
            if (fn != null) {
              if (fn['name'] != null) partial.name = fn['name'] as String;
              if (fn['arguments'] != null) {
                partial.arguments += fn['arguments'] as String;
              }
            }
          }
        }

        final u = json['usage'] as Map<String, dynamic>?;
        if (u != null) {
          usage = TokenUsage(
            prompt: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
            completion: (u['completion_tokens'] as num?)?.toInt() ?? 0,
            total: (u['total_tokens'] as num?)?.toInt() ?? 0,
          );
        }

        final finish = (choices.first as Map)['finish_reason'] as String?;
        if (finish != null && finish != 'null') {
          // will be emitted after stream ends
        }
      } catch (_) {
        // skip malformed SSE lines
      }
    }
  }

  Stream<LlmEvent> _nonStreamChat(
    http.Client client,
    Map<String, dynamic> body,
  ) async* {
    final response = await client.post(
      _chatUri,
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode >= 400) {
      yield LlmError(
        'HTTP ${response.statusCode}: ${response.body}',
        code: '${response.statusCode}',
      );
      return;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      yield const LlmDone();
      return;
    }
    final msg =
        (choices.first as Map<String, dynamic>)['message']
            as Map<String, dynamic>? ??
        {};
    final content = msg['content'] as String?;
    if (content != null && content.isNotEmpty) yield LlmTextDelta(content);

    final tcs = msg['tool_calls'] as List<dynamic>?;
    if (tcs != null) {
      for (final raw in tcs) {
        yield LlmToolCall(ToolCall.fromJson(raw as Map<String, dynamic>));
      }
    }

    final u = json['usage'] as Map<String, dynamic>?;
    if (u != null) {
      yield LlmUsage(
        TokenUsage(
          prompt: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
          completion: (u['completion_tokens'] as num?)?.toInt() ?? 0,
          total: (u['total_tokens'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final finish = (choices.first as Map)['finish_reason'] as String? ?? 'stop';
    yield LlmDone(finishReason: finish);
  }

  @override
  Future<List<double>> embed(String text) async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base/embeddings');
    final client = httpClient ?? http.Client();
    try {
      final res = await client.post(
        uri,
        headers: _headers,
        body: jsonEncode({'model': model, 'input': text}),
      );
      if (res.statusCode >= 400) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return const [];
      final emb = (data.first as Map)['embedding'] as List<dynamic>?;
      return emb?.map((e) => (e as num).toDouble()).toList() ?? const [];
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

class _PartialToolCall {
  _PartialToolCall(this.index);
  final int index;
  String? id;
  String? name;
  String arguments = '';
}
