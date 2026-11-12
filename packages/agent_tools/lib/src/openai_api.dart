import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// OpenAI-compatible HTTP endpoint (Hermes-style API Server).
///
/// Exposes the agent as an OpenAI-format backend so any OpenAI-speaking
/// frontend (Open WebUI, LobeChat, LibreChat, …) can connect:
/// - `POST /v1/chat/completions` — streaming (SSE) and non-streaming.
/// - `GET /v1/models` — model list.
/// - `GET /health` — liveness, no auth.
///
/// All other routes require `Authorization: Bearer <apiKey>`. The server
/// binds to [OpenAiCompatConfig.host] (default loopback) only; exposing it
/// remotely is the host operator's responsibility (TLS/reverse proxy).

class OpenAiCompatConfig {
  const OpenAiCompatConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    required this.apiKey,
    this.models = const ['tiko-agent'],
    this.requestTimeout = const Duration(minutes: 5),
  });

  final String host;
  final int port;

  /// Bearer token required on every endpoint except `/health`.
  final String apiKey;
  final List<String> models;
  final Duration requestTimeout;
}

/// One normalized chat message from the OpenAI payload.
class OpenAiChatMessage {
  const OpenAiChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

/// Decoded `/v1/chat/completions` request.
class OpenAiChatRequest {
  const OpenAiChatRequest({
    required this.model,
    required this.messages,
    this.maxTokens,
    this.temperature,
    this.stream = false,
  });

  final String model;
  final List<OpenAiChatMessage> messages;
  final int? maxTokens;
  final double? temperature;
  final bool stream;

  String get lastUserText {
    for (final m in messages.reversed) {
      if (m.role == 'user') return m.content;
    }
    return messages.isEmpty ? '' : messages.last.content;
  }

  String get systemText => messages
      .where((m) => m.role == 'system')
      .map((m) => m.content)
      .join('\n');
}

/// Host callback that runs the agent and returns the final answer text.
typedef OpenAiChatHandler = Future<String> Function(OpenAiChatRequest req);

/// HTTP server speaking the OpenAI chat-completions wire format.
class OpenAiCompatServer {
  OpenAiCompatServer({required this.config, required this.handler});

  final OpenAiCompatConfig config;
  final OpenAiChatHandler handler;

  HttpServer? _server;

  int get port => _server?.port ?? config.port;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(config.host, config.port);
    _server!.listen(
      (req) => _handle(req),
      onError: (Object _) {},
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path == '/health') {
        return await _json(req, 200, {'status': 'ok'});
      }
      if (!_authorized(req)) {
        return await _json(req, 401, {
          'error': {
            'message': 'Missing or invalid bearer token',
            'type': 'authentication_error',
          },
        });
      }
      final path = req.uri.path.replaceAll(RegExp(r'/+$'), '');
      if (req.method == 'GET' && path == '/v1/models') {
        return await _json(req, 200, {
          'object': 'list',
          'data': [
            for (final m in config.models)
              {'id': m, 'object': 'model', 'owned_by': 'tiko-agent'},
          ],
        });
      }
      if (req.method == 'POST' && path == '/v1/chat/completions') {
        return await _chatCompletions(req);
      }
      await _json(req, 404, {
        'error': {'message': 'Not found: ${req.uri.path}', 'type': 'invalid_request_error'},
      });
    } catch (e) {
      await _json(req, 500, {
        'error': {'message': e.toString(), 'type': 'server_error'},
      });
    }
  }

  bool _authorized(HttpRequest req) {
    final header = req.headers.value('Authorization') ?? '';
    return header == 'Bearer ${config.apiKey}';
  }

  Future<void> _chatCompletions(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return await _json(req, 400, {
        'error': {'message': 'Invalid JSON body', 'type': 'invalid_request_error'},
      });
    }
    final request = _decodeRequest(payload);
    final id = 'chatcmpl-${_randomId()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (request.stream) {
      req.response.headers
        ..contentType = ContentType('text', 'event-stream')
        ..set('Cache-Control', 'no-cache')
        ..set('Connection', 'keep-alive');
      final answer = await handler(request);
      for (final piece in _chunkText(answer)) {
        req.response.write('data: ${jsonEncode({
              'id': id,
              'object': 'chat.completion.chunk',
              'created': created,
              'model': request.model,
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': piece},
                  'finish_reason': null,
                },
              ],
            })}\n\n');
        await req.response.flush();
      }
      req.response.write('data: ${jsonEncode({
            'id': id,
            'object': 'chat.completion.chunk',
            'created': created,
            'model': request.model,
            'choices': [
              {
                'index': 0,
                'delta': {},
                'finish_reason': 'stop',
              },
            ],
          })}\n\n');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
      return;
    }

    final answer = await handler(request);
    await _json(req, 200, {
      'id': id,
      'object': 'chat.completion',
      'created': created,
      'model': request.model,
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': answer},
          'finish_reason': 'stop',
        },
      ],
      'usage': {
        'prompt_tokens': _estimateTokens(request.lastUserText),
        'completion_tokens': _estimateTokens(answer),
        'total_tokens':
            _estimateTokens(request.lastUserText) + _estimateTokens(answer),
      },
    });
  }

  OpenAiChatRequest _decodeRequest(Map<String, dynamic> payload) {
    final rawMessages = payload['messages'];
    if (rawMessages is! List || rawMessages.isEmpty) {
      throw ArgumentError('messages must be a non-empty array');
    }
    final messages = <OpenAiChatMessage>[];
    for (final raw in rawMessages) {
      if (raw is! Map) continue;
      messages.add(OpenAiChatMessage(
        role: raw['role'] as String? ?? 'user',
        content: raw['content'] as String? ?? '',
      ));
    }
    return OpenAiChatRequest(
      model: payload['model'] as String? ?? config.models.first,
      messages: messages,
      maxTokens: (payload['max_tokens'] as num?)?.toInt(),
      temperature: (payload['temperature'] as num?)?.toDouble(),
      stream: payload['stream'] == true,
    );
  }

  Future<void> _json(HttpRequest req, int status, Object body) async {
    req.response.headers.contentType = ContentType.json;
    req.response.statusCode = status;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  static List<String> _chunkText(String text, {int chunkChars = 24}) {
    if (text.isEmpty) return const [];
    final chunks = <String>[];
    for (var i = 0; i < text.length; i += chunkChars) {
      chunks.add(text.substring(i, math.min(i + chunkChars, text.length)));
    }
    return chunks;
  }

  static int _estimateTokens(String text) =>
      text.isEmpty ? 0 : (text.length / 4).ceil();

  static String _randomId() {
    final rand = math.Random();
    return List.generate(
      12,
      (_) => '0123456789abcdef'[rand.nextInt(16)],
    ).join();
  }
}
