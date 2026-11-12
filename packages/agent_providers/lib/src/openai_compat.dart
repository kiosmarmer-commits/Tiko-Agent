import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'credential_pool.dart';
import 'prompt_cache.dart';

/// Thin OpenAI-compatible chat provider (Ollama /v1, LM Studio, OpenRouter, Groq, …).
/// TASK-02-01: streaming + tool calling.
///
/// Hermes-parity extensions: credential pool rotation (401/429), OAuth device
/// token injection, per-provider/model request timeout, and model discovery
/// via GET /models.
class OpenAiCompatProvider implements LlmProvider {
  OpenAiCompatProvider({
    required this.id,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.httpClient,
    this.promptCache,
    this.credentialPool,
    this.tokenProvider,
    this.requestTimeout,
    this.modelTimeouts = const {},
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

  /// Multi-key rotation for the same provider; used when [apiKey] is null.
  final CredentialPool? credentialPool;

  /// Resolves a bearer token per request (e.g. OAuth device flow cache).
  final Future<String?> Function()? tokenProvider;

  /// Provider-wide request timeout (connection + response headers).
  final Duration? requestTimeout;

  /// Per-model timeout override (seconds), checked with `req.model ?? model`.
  final Map<String, int> modelTimeouts;

  /// When set, stable system prefixes are tracked cross-session and the
  /// OpenAI-style `prompt_cache_key` hint is attached so compatible backends
  /// (OpenAI, OpenRouter, vLLM, …) reuse the cached prefix.
  final PromptCacheManager? promptCache;

  @override
  final Capabilities capabilities;

  Uri get chatUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  Future<String?> resolveKey() async {
    if (apiKey != null && apiKey!.isNotEmpty) return apiKey;
    final pool = credentialPool;
    if (pool != null && pool.length > 0) return pool.current;
    final tp = tokenProvider;
    if (tp != null) return await tp();
    return null;
  }

  Future<Map<String, String>> headersFor(String? key) async => {
        'Content-Type': 'application/json',
        if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
      };

  Duration? _timeoutFor(String modelId) {
    final perModel = modelTimeouts[modelId];
    if (perModel != null && perModel > 0) return Duration(seconds: perModel);
    return requestTimeout;
  }

  @override
  Stream<LlmEvent> chat(ChatRequest req) async* {
    final attempts = (credentialPool != null && credentialPool!.length > 1)
        ? credentialPool!.length
        : 1;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final key = await resolveKey();
      final headers = await headersFor(key);
      final events = _chat(req, headers);
      if (attempt == attempts) {
        yield* events;
        return;
      }
      final it = StreamIterator(events);
      if (!await it.moveNext()) return;
      final first = it.current;
      if (first is LlmError && _shouldRotate(first.code)) {
        credentialPool?.reportFailure();
        continue;
      }
      yield first;
      while (await it.moveNext()) {
        yield it.current;
      }
      return;
    }
  }

  bool _shouldRotate(String? code) =>
      code == '401' || code == '403' || code == '429';

  Stream<LlmEvent> _chat(
    ChatRequest req,
    Map<String, String> headers,
  ) async* {
    final cache = promptCache;
    String? systemPrompt;
    for (final m in req.messages) {
      if (m.role == 'system') {
        systemPrompt = (systemPrompt == null) ? m.content : '$systemPrompt\n${m.content}';
      }
    }
    String? cacheKey;
    if (cache != null && systemPrompt != null) {
      cache.observe(model: req.model ?? model, systemPrompt: systemPrompt);
      cacheKey = cache.cacheKey(model: req.model ?? model, systemPrompt: systemPrompt);
    }
    final body = <String, dynamic>{
      'model': req.model ?? model,
      'messages': req.messages.map((m) => m.toJson()).toList(),
      'stream': req.stream,
      if (cacheKey != null) 'prompt_cache_key': cacheKey,
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
        yield* _streamChat(client, body, headers);
      } else {
        yield* _nonStreamChat(client, body, headers);
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
    Map<String, String> headers,
  ) async* {
    final request = http.Request('POST', chatUri)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);

    final timeout = _timeoutFor(body['model'] as String? ?? model);
    final response = await client
        .send(request)
        .timeout(timeout ?? const Duration(hours: 1));
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
    Map<String, String> headers,
  ) async* {
    final timeout = _timeoutFor(body['model'] as String? ?? model);
    final response = await client
        .post(chatUri, headers: headers, body: jsonEncode(body))
        .timeout(timeout ?? const Duration(hours: 1));
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

  /// Lists model ids advertised by the endpoint (Hermes-parity
  /// `discover_models`). Returns an empty list on any error.
  Future<List<String>> discoverModels() async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final client = httpClient ?? http.Client();
    try {
      final key = await resolveKey();
      final res = await client
          .get(Uri.parse('$base/models'), headers: await headersFor(key))
          .timeout(requestTimeout ?? const Duration(seconds: 30));
      if (res.statusCode >= 400) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>?;
      if (data == null) return const [];
      return [
        for (final e in data)
          if (e is Map && e['id'] is String) e['id'] as String,
      ];
    } catch (_) {
      return const [];
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base/embeddings');
    final client = httpClient ?? http.Client();
    try {
      final key = await resolveKey();
      final res = await client.post(
        uri,
        headers: await headersFor(key),
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
