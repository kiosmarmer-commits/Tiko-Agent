import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// MCP "Streamable HTTP" client transport (agent spec 2025-03-26 /
/// 2025-06-18), self-contained: POST JSON-RPC to the endpoint, accept
/// either `application/json` or `text/event-stream` responses.
///
/// Supports: initialize (protocol version handshake), tools/list,
/// tools/call, plus generic [call]. Server-initiated requests and
/// notifications are collected into [notifications] for inspection.
///
/// NOTE: this client is intentionally standalone. Adapting it to the
/// existing `mcp/registry_mcp.dart` transport interface is follow-up work
/// (see MANIFEST); the class boundaries here are stable.
class McpStreamableHttpClient {
  McpStreamableHttpClient({
    required this.endpoint,
    Map<String, String>? headers,
    this.client,
    this.timeout = const Duration(seconds: 30),
    this.clientInfo = const {
      'name': 'tiko-agent',
      'version': '0.2.0',
    },
  });

  /// The MCP server endpoint (https://host/mcp).
  final Uri endpoint;

  /// Extra headers (e.g. Authorization: Bearer ...).
  final Map<String, String>? headers;

  final http.Client? client;
  final Duration timeout;
  final Map<String, String> clientInfo;

  http.Client get _client => client ?? http.Client();

  /// Session id assigned by the server (Mcp-Session-Id response header).
  String? _sessionId;

  /// JSON-RPC ids are monotonically increasing per client instance.
  int _nextId = 1;

  /// Server notifications (requests without an id) seen so far.
  final List<Map<String, dynamic>> notifications = [];

  bool get initialized => _sessionId != null || _initializeAck;

  bool _initializeAck = false;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
        ...?headers,
      };

  /// JSON-RPC initialize handshake. Must be the first call.
  Future<Map<String, dynamic>> initialize() async {
    final resp = await _rpc(
      'initialize',
      {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': clientInfo,
      },
      storeSession: true,
    );
    _initializeAck = true;
    return resp['result'] as Map<String, dynamic>? ?? const {};
  }

  /// Sends `notifications/initialized`.
  Future<void> notifyInitialized() async {
    await _post(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }));
  }

  /// Lists the server's tools: [{name, description, inputSchema}].
  Future<List<Map<String, dynamic>>> listTools() async {
    final resp = await _rpc('tools/list', const {});
    final result = resp['result'];
    if (result is! Map) return const [];
    final tools = result['tools'];
    if (tools is! List) return const [];
    return tools.whereType<Map<String, dynamic>>().toList();
  }

  /// Calls a tool; returns {content: [...], isError: bool}.
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final resp = await _rpc('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final result = resp['result'];
    if (result is Map<String, dynamic>) return result;
    if (resp['error'] != null) {
      return {
        'content': [
          {'type': 'text', 'text': 'MCP error: ${resp['error']}'}
        ],
        'isError': true,
      };
    }
    return {'content': const [], 'isError': true};
  }

  /// Generic JSON-RPC call (resources, prompts, ...).
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) =>
      _rpc(method, params);

  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params, {
    bool storeSession = false,
  }) async {
    final id = _nextId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final decoded = await _post(body);
    final matches = _matchingResponse(decoded, id);
    if (matches == null) {
      throw StateError('MCP server tidak membalas id $id ($method)');
    }
    if (storeSession) {
      final sid = matches['header_mcp_session_id'];
      if (sid is String && sid.isNotEmpty) _sessionId = sid;
    }
    return matches;
  }

  /// POSTs [body], parses JSON or SSE, returns the first JSON-RPC object
  /// found. Session headers are captured when present.
  Future<Map<String, dynamic>> _post(String body) async {
    final resp = await _client
        .post(endpoint, headers: _headers, body: body)
        .timeout(timeout);
    if (resp.statusCode >= 400) {
      throw StateError('MCP HTTP ${resp.statusCode}: '
          '${utf8.decode(resp.bodyBytes, allowMalformed: true).substring(0, 200)}');
    }
    final sid = resp.headers['mcp-session-id'];
    final contentType = resp.headers['content-type'] ?? '';
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);

    Map<String, dynamic>? decoded;
    if (contentType.contains('text/event-stream')) {
      decoded = _firstJsonFromSse(text);
    } else {
      try {
        final m = jsonDecode(text);
        if (m is Map<String, dynamic>) decoded = m;
      } catch (_) {
        decoded = _firstJsonFromSse(text); // servers that lie about type
      }
    }
    if (decoded == null) {
      throw StateError('MCP respons tidak dikenali: '
          '${text.substring(0, text.length < 200 ? text.length : 200)}');
    }
    return {...decoded, if (sid != null) 'header_mcp_session_id': sid};
  }

  /// Extracts JSON objects from SSE `data:` lines. Records id-less objects
  /// (notifications) into [notifications].
  Map<String, dynamic>? _firstJsonFromSse(String sse) {
    Map<String, dynamic>? found;
    for (final block in sse.split(RegExp(r'\r?\n\r?\n'))) {
      final data = StringBuffer();
      for (final line in block.split(RegExp(r'\r?\n'))) {
        if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
        }
      }
      final payload = data.toString().trim();
      if (payload.isEmpty) continue;
      try {
        final m = jsonDecode(payload);
        if (m is Map<String, dynamic>) {
          if (m['id'] == null) {
            notifications.add(m);
            continue;
          }
          found ??= m;
        }
      } catch (_) {
        // multi-line JSON chunks are rare in MCP; ignore partials
      }
    }
    return found;
  }

  Map<String, dynamic>? _matchingResponse(
    Map<String, dynamic> decoded,
    int id,
  ) =>
      decoded['id'] == id ? decoded : null;

  Future<void> close() async {
    notifications.clear();
    _sessionId = null;
    _initializeAck = false;
  }
}
