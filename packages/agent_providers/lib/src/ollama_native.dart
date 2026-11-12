import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Native Ollama `/api/chat` provider (shape compatible with ollama_dart usage).
class OllamaNativeProvider implements LlmProvider {
  OllamaNativeProvider({
    this.id = 'ollama_native',
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'qwen2.5:3b',
    http.Client? client,
  }) : _client = client;

  @override
  final String id;
  final String baseUrl;
  final String model;
  final http.Client? _client;

  @override
  Capabilities get capabilities =>
      const Capabilities(toolCalling: true, streaming: true, maxContext: 32000);

  @override
  Stream<LlmEvent> chat(ChatRequest request) async* {
    final client = _client ?? http.Client();
    try {
      final messages = request.messages
          .map(
            (m) => {
              'role': m.role == 'tool' ? 'tool' : m.role,
              'content': m.content,
              if (m.name != null) 'name': m.name,
            },
          )
          .toList();
      final tools = request.tools
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
          .toList();

      final body = {
        'model': model,
        'messages': messages,
        'stream': request.stream,
        if (tools.isNotEmpty) 'tools': tools,
        'options': {
          if (request.temperature != null) 'temperature': request.temperature,
          if (request.maxTokens != null) 'num_predict': request.maxTokens,
        },
      };

      final uri = Uri.parse('$baseUrl/api/chat');
      if (!request.stream) {
        final res = await client
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 180));
        if (res.statusCode >= 400) {
          yield LlmError('Ollama ${res.statusCode}: ${res.body}');
          return;
        }
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        yield* _emitMessage(json);
        return;
      }

      final req = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 180));
      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          yield* _emitMessage(json);
          if (json['done'] == true) break;
        } catch (_) {}
      }
    } catch (e) {
      yield LlmError(e.toString());
    } finally {
      if (_client == null) client.close();
    }
  }

  Stream<LlmEvent> _emitMessage(Map<String, dynamic> json) async* {
    final msg = json['message'] as Map<String, dynamic>?;
    if (msg == null) return;
    final content = msg['content'] as String? ?? '';
    if (content.isNotEmpty) yield LlmTextDelta(content);
    final toolCalls = msg['tool_calls'] as List<dynamic>?;
    if (toolCalls != null) {
      for (final tc in toolCalls) {
        final m = tc as Map<String, dynamic>;
        final fn = m['function'] as Map<String, dynamic>? ?? {};
        final name = fn['name'] as String? ?? '';
        var args = <String, dynamic>{};
        final a = fn['arguments'];
        if (a is String) {
          try {
            args = jsonDecode(a) as Map<String, dynamic>;
          } catch (_) {}
        } else if (a is Map) {
          args = Map<String, dynamic>.from(a);
        }
        yield LlmToolCall(
          ToolCall(
            id: m['id'] as String? ?? 'call_${name.hashCode}',
            name: name,
            args: args,
          ),
        );
      }
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    final client = _client ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('$baseUrl/api/embeddings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': model, 'prompt': text}),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode >= 400) return const [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return (json['embedding'] as List<dynamic>? ?? [])
          .map((e) => (e as num).toDouble())
          .toList();
    } catch (_) {
      return const [];
    } finally {
      if (_client == null) client.close();
    }
  }
}

/// MCP adapter note: use existing StdioMcpClient / HttpMcpClient.
/// When package `mcp` or `dart_mcp` is added via pub, wrap behind McpTransport.
class McpAdapterFactory {
  static String docs =
      'StdioMcpClient + HttpMcpClient already implement MCP JSON-RPC. '
      'To use an official package, implement McpTransport and register tools.';
}
