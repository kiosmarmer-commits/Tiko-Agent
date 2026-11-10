import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'dart:io';

/// Agent Client Protocol (ACP) endpoint — JSON-RPC 2.0 over newline-
/// delimited stdio, the protocol used by ACP-compatible editors
/// (Zed, VS Code via extensions, JetBrains).
///
/// Supported agent-side methods:
/// - `initialize` → protocol version + agent capabilities.
/// - `session/new` → fresh session id (accepts `cwd`).
/// - `session/prompt` → runs the injected handler, streams
///   `session/update` notifications (`agent_message_chunk`) and answers
///   with `{stopReason: "end_turn"}`.
/// - `session/cancel` → marks the session cancelled (observed between
///   prompts).
///
/// I/O is injectable: production wires stdin/stdout, tests wire
/// StreamControllers.

class AcpAgentConfig {
  const AcpAgentConfig({
    this.name = 'tiko-agent',
    this.version = '0.1.0',
    this.protocolVersion = 1,
  });

  final String name;
  final String version;

  /// ACP protocol version advertised during initialize.
  final int protocolVersion;
}

/// Runs the agent for one user prompt and returns the final answer.
typedef AcpPromptHandler = Future<String> Function(
  String sessionId,
  String prompt,
);

/// JSON-RPC 2.0 ACP agent side.
class AcpAgent {
  AcpAgent({
    required this.handler,
    this.config = const AcpAgentConfig(),
    Stream<String>? input,
    void Function(String line)? output,
  })  : _input = input ?? stdin.transform(utf8.decoder),
        _output = output ?? ((line) => stdout.writeln(line));

  final AcpPromptHandler handler;
  final AcpAgentConfig config;
  final Stream<String> _input;
  final void Function(String line) _output;

  final Set<String> _cancelled = {};
  StreamSubscription<String>? _subscription;

  bool get isServing => _subscription != null;

  /// Starts serving requests until the input stream closes.
  Future<void> serve() async {
    if (isServing) return;
    final completer = Completer<void>();
    _subscription = _input.listen(
      (line) => _handleLine(line),
      onDone: () => completer.complete(),
      onError: (Object _) => completer.complete(),
    );
    await completer.future;
    _subscription = null;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Map<String, dynamic>? message;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) message = decoded;
    } catch (_) {}
    if (message == null) {
      _send({'jsonrpc': '2.0', 'id': null, 'error': {
        'code': -32700,
        'message': 'Parse error',
      }});
      return;
    }
    final method = message['method'] as String?;
    final id = message['id'];
    final params = message['params'];
    if (method == null) {
      _sendError(id, -32600, 'Invalid Request: missing method');
      return;
    }
    if (id == null) {
      _handleNotification(method, params);
      return;
    }
    _handleRequest(id, method, params);
  }

  void _handleRequest(dynamic id, String method, dynamic params) {
    switch (method) {
      case 'initialize':
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': config.protocolVersion,
            'agentCapabilities': {
              'loadSession': false,
              'promptCapabilities': {'embeddedContext': false},
            },
            'agentInfo': {'name': config.name, 'version': config.version},
          },
        });
        return;
      case 'session/new':
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'sessionId': _newSessionId()},
        });
        return;
      case 'session/prompt':
        unawaited(_handlePrompt(id, params));
        return;
      case 'session/load':
        _sendError(id, -32601, 'loadSession is not supported');
        return;
      default:
        _sendError(id, -32601, 'Method not found: $method');
    }
  }

  Future<void> _handlePrompt(dynamic id, dynamic params) async {
    final map = params is Map<String, dynamic> ? params : const {};
    final sessionId = map['sessionId'] as String? ?? _newSessionId();
    final prompt = _extractPrompt(map['prompt']);

    String answer;
    try {
      answer = await handler(sessionId, prompt);
    } catch (e) {
      _cancelled.remove(sessionId);
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'stopReason': 'error'},
      });
      _send({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': sessionId,
          'update': {
            'sessionUpdate': 'error',
            'content': {'type': 'text', 'text': e.toString()},
          },
        },
      });
      return;
    }
    if (_cancelled.contains(sessionId)) {
      _cancelled.remove(sessionId);
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'stopReason': 'cancelled'},
      });
      return;
    }
    _cancelled.remove(sessionId);
    for (final chunk in _chunks(answer)) {
      _send({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': sessionId,
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': chunk},
          },
        },
      });
    }
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'result': {'stopReason': 'end_turn'},
    });
  }

  void _handleNotification(String method, dynamic params) {
    switch (method) {
      case 'session/cancel':
        final map = params is Map<String, dynamic> ? params : const {};
        final sessionId = map['sessionId'] as String?;
        if (sessionId != null) _cancelled.add(sessionId);
        return;
      default:
        return;
    }
  }

  String _extractPrompt(dynamic prompt) {
    if (prompt is String) return prompt;
    if (prompt is List) {
      return [
        for (final block in prompt)
          if (block is Map && block['type'] == 'text')
            block['text'] as String? ?? '',
      ].where((s) => s.isNotEmpty).join('\n');
    }
    return '';
  }

  void _send(Map<String, dynamic> message) =>
      _output(jsonEncode(message));

  void _sendError(dynamic id, int code, String message) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });

  String _newSessionId() {
    final rand = math.Random();
    return List.generate(
      16,
      (_) => '0123456789abcdef'[rand.nextInt(16)],
    ).join();
  }

  static List<String> _chunks(String text, {int chunkChars = 64}) {
    if (text.isEmpty) return const [];
    final chunks = <String>[];
    for (var i = 0; i < text.length; i += chunkChars) {
      chunks.add(text.substring(i, math.min(i + chunkChars, text.length)));
    }
    return chunks;
  }
}
