import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'dart:io';

/// Agent Client Protocol (ACP) — JSON-RPC 2.0, the protocol used by
/// ACP-compatible editors (Zed, VS Code via extensions, JetBrains).
///
/// The protocol core lives in [AcpDispatcher], a transport-agnostic class
/// that turns decoded JSON-RPC messages into responses and
/// `session/update` notifications. Two transports share it:
/// - [AcpAgent] — newline-delimited stdio (the standard ACP transport).
/// - `IdeIntegrationManager` — HTTP POST endpoint for IDE extensions.
///
/// Supported agent-side methods:
/// - `initialize` → protocol version + agent capabilities.
/// - `session/new` → fresh session id (accepts `cwd`).
/// - `session/prompt` → runs the injected handler, emits
///   `session/update` notifications (`agent_message_chunk`) and answers
///   with `{stopReason: "end_turn"}`.
/// - `session/cancel` → marks the session cancelled (observed between
///   prompts).
/// - `session/load` → when an [AcpSessionLoader] is injected, resolves a
///   stored session and replays its history as `session/update`
///   notifications (`user_message_chunk` / `agent_message_chunk`).
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

/// One replayed message from a loaded session.
class AcpHistoryEntry {
  const AcpHistoryEntry({required this.role, required this.text});

  /// `user` or `assistant`.
  final String role;
  final String text;
}

/// Resolves an ACP session id to its stored history. Returns null when the
/// session does not exist; otherwise returns the messages oldest first.
typedef AcpSessionLoader = Future<List<AcpHistoryEntry>?> Function(
  String sessionId,
);

/// Transport-agnostic JSON-RPC 2.0 ACP protocol core.
///
/// [emit] receives every outgoing message (notifications, updates and
/// responses) in emission order. [dispatch] resolves with the response
/// map for requests (null for notifications), after all notifications
/// for that request have been emitted — so transports that need a single
/// reply (HTTP) can await [dispatch] while streaming transports (stdio)
/// receive notifications through [emit] as they happen.
class AcpDispatcher {
  AcpDispatcher({
    required this.handler,
    this.config = const AcpAgentConfig(),
    required this.emit,
    this.sessionLoader,
  });

  final AcpPromptHandler handler;
  final AcpAgentConfig config;
  final void Function(Map<String, dynamic> message) emit;

  /// When provided, `session/load` resolves stored sessions and replays
  /// their history as `session/update` notifications.
  final AcpSessionLoader? sessionLoader;

  final Set<String> _cancelled = {};

  /// Handles one decoded JSON-RPC message. Returns the response map for
  /// requests, or null for notifications and malformed input.
  Future<Map<String, dynamic>?> dispatch(Map<String, dynamic> message) async {
    final method = message['method'] as String?;
    final id = message['id'];
    final params = message['params'];
    if (method == null) {
      return _error(id, -32600, 'Invalid Request: missing method');
    }
    if (id == null) {
      _handleNotification(method, params);
      return null;
    }
    return _handleRequest(id, method, params);
  }

  Future<Map<String, dynamic>?> _handleRequest(
    dynamic id,
    String method,
    dynamic params,
  ) async {
    switch (method) {
      case 'initialize':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': config.protocolVersion,
            'agentCapabilities': {
              'loadSession': sessionLoader != null,
              'promptCapabilities': {'embeddedContext': false},
            },
            'agentInfo': {'name': config.name, 'version': config.version},
          },
        };
      case 'session/new':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {'sessionId': _newSessionId()},
        };
      case 'session/prompt':
        return _handlePrompt(id, params);
      case 'session/load':
        return _handleLoad(id, params);
      default:
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  Future<Map<String, dynamic>> _handlePrompt(dynamic id, dynamic params) async {
    final map = params is Map<String, dynamic> ? params : const {};
    final sessionId = map['sessionId'] as String? ?? _newSessionId();
    final prompt = _extractPrompt(map['prompt']);

    String answer;
    try {
      answer = await handler(sessionId, prompt);
    } catch (e) {
      _cancelled.remove(sessionId);
      emit(_sessionUpdate(sessionId, 'error', e.toString()));
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {'stopReason': 'error'},
      };
    }
    if (_cancelled.contains(sessionId)) {
      _cancelled.remove(sessionId);
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {'stopReason': 'cancelled'},
      };
    }
    _cancelled.remove(sessionId);
    for (final chunk in _chunks(answer)) {
      emit(_sessionUpdate(sessionId, 'agent_message_chunk', chunk));
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {'stopReason': 'end_turn'},
    };
  }

  Future<Map<String, dynamic>> _handleLoad(dynamic id, dynamic params) async {
    final loader = sessionLoader;
    if (loader == null) {
      return _error(id, -32601, 'loadSession is not supported');
    }
    final map = params is Map<String, dynamic> ? params : const {};
    final sessionId = map['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return _error(id, -32602, 'session/load requires a sessionId');
    }
    final List<AcpHistoryEntry> history;
    try {
      history = await loader(sessionId) ?? const <AcpHistoryEntry>[];
    } catch (e) {
      return _error(id, -32603, 'session/load failed: $e');
    }
    for (final entry in history) {
      emit(_sessionUpdate(
        sessionId,
        entry.role == 'user' ? 'user_message_chunk' : 'agent_message_chunk',
        entry.text,
      ));
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {'sessionId': sessionId},
    };
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

  Map<String, dynamic> _sessionUpdate(
    String sessionId,
    String updateType,
    String text,
  ) =>
      {
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': sessionId,
          'update': {
            'sessionUpdate': updateType,
            'content': {'type': 'text', 'text': text},
          },
        },
      };

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

  Map<String, dynamic> _error(dynamic id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

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

/// JSON-RPC 2.0 ACP agent side over newline-delimited stdio.
class AcpAgent {
  AcpAgent({
    required this.handler,
    this.config = const AcpAgentConfig(),
    this.sessionLoader,
    Stream<String>? input,
    void Function(String line)? output,
  })  : _input = input ?? stdin.transform(utf8.decoder),
        _output = output ?? ((line) => stdout.writeln(line)) {
    _dispatcher = AcpDispatcher(
      handler: handler,
      config: config,
      sessionLoader: sessionLoader,
      emit: (message) => _output(jsonEncode(message)),
    );
  }

  final AcpPromptHandler handler;
  final AcpAgentConfig config;
  final AcpSessionLoader? sessionLoader;
  final Stream<String> _input;
  final void Function(String line) _output;

  late final AcpDispatcher _dispatcher;

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
      _output(jsonEncode({
        'jsonrpc': '2.0',
        'id': null,
        'error': {
          'code': -32700,
          'message': 'Parse error',
        },
      }));
      return;
    }
    unawaited(_dispatcher.dispatch(message).then((response) {
      if (response != null) _output(jsonEncode(response));
    }));
  }
}
