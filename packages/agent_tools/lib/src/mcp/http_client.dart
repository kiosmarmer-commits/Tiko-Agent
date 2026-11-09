import 'dart:convert';

import 'package:http/http.dart' as http;

import 'transport.dart';
import 'stdio_client.dart' show McpToolInfo, McpToolServer;

/// MCP client over Streamable HTTP (JSON-RPC POST, optional SSE responses).
///
/// Implements the Streamable HTTP session lifecycle:
/// - captures the mcp-session-id header assigned by the server during
///   initialize and echoes it on every subsequent request;
/// - accepts single JSON, JSON batch, and text/event-stream responses;
/// - collects server notifications that arrive alongside responses;
/// - terminates the session with a best-effort DELETE on close.
class HttpMcpClient implements McpTransport, McpToolServer {
  HttpMcpClient({
    required this.baseUrl,
    this.headers = const {},
    this.httpClient,
    this.protocolVersion = '2025-11-25',
    this.maxOutputChars = 100000,
  });

  final String baseUrl;
  final Map<String, String> headers;
  final http.Client? httpClient;
  final String protocolVersion;

  /// Batas total karakter keluaran tool sebelum ditolak.
  final int maxOutputChars;

  int _nextId = 1;
  bool _started = false;
  Future<void>? _starting;
  String? _sessionId;
  String? serverName;

  /// Session id yang diberikan server saat initialize, bila ada.
  String? get sessionId => _sessionId;

  /// Notifikasi dari server yang diterima sejak start.
  final List<Map<String, dynamic>> notifications = [];

  @override
  Future<void> start() async {
    final pending = _starting ??= _start();
    try {
      await pending;
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  Future<void> _start() async {
    final init = await _send('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': {'tools': {}},
      'clientInfo': {'name': 'tiko', 'version': '0.1.0'},
    });
    final info = init['serverInfo'];
    if (info is Map && info['name'] is String) {
      serverName = info['name'] as String;
    }
    await _sendNotification('notifications/initialized');
    _started = true;
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (!_started) await start();
    return _send(method, params);
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    if (!_started) await start();
    await _sendNotification(method, params);
  }

  /// List tools exposed by the server. Names and schemas are untrusted
  /// config inputs; malformed entries abort loading instead of being
  /// partially used.
  @override
  Future<List<McpToolInfo>> listTools() async {
    final res = await request('tools/list');
    final raw = res['tools'];
    if (raw is! List || raw.length > 128) {
      throw const FormatException('invalid MCP tools/list response');
    }
    return raw.map((item) {
      if (item is! Map) throw const FormatException('invalid MCP tool entry');
      final name = item['name'];
      final description = item['description'];
      final schema = item['inputSchema'];
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$').hasMatch(name)) {
        throw const FormatException('invalid MCP tool name');
      }
      if (description != null && description is! String) {
        throw const FormatException('invalid MCP tool description');
      }
      if (schema != null && schema is! Map) {
        throw const FormatException('invalid MCP input schema');
      }
      final descriptionText = description as String? ?? '';
      return McpToolInfo(
        name: name,
        description: descriptionText.length > 2000
            ? descriptionText.substring(0, 2000)
            : descriptionText,
        inputSchema: schema is Map
            ? Map<String, dynamic>.from(schema)
            : const {'type': 'object', 'properties': <String, dynamic>{}},
      );
    }).toList(growable: false);
  }

  /// Call a server tool. Output is untrusted and always wrapped in an
  /// untrusted_data envelope with escaped inner delimiters.
  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final res = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final content = res['content'];
    if (content == null) return jsonEncode(res);
    if (content is! List || content.length > 128) {
      throw const FormatException('invalid MCP tool result content');
    }
    final texts = <String>[];
    var totalChars = 0;
    for (final item in content) {
      if (item is! Map) continue;
      if (item['type'] == 'text') {
        final text = item['text'];
        if (text is String) {
          totalChars += text.length;
          if (totalChars > maxOutputChars) {
            throw const FormatException('MCP output too large');
          }
          texts.add(text);
        }
      } else {
        final encoded = jsonEncode(item);
        totalChars += encoded.length;
        if (totalChars > maxOutputChars) {
          throw const FormatException('MCP output too large');
        }
        texts.add(encoded);
      }
    }
    final body = texts.join('\n');
    if (res['isError'] == true) return 'MCP error: $body';
    final safeSource =
        (serverName ?? 'server').replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final safeBody = body
        .replaceAll('</untrusted_data', '<\\/untrusted_data')
        .replaceAll('<untrusted_data', '<\\untrusted_data');
    return '<untrusted_data source="mcp-http:$safeSource">\n$safeBody\n</untrusted_data>';
  }

  @override
  Future<void> close() async {
    final sid = _sessionId;
    _sessionId = null;
    _started = false;
    _starting = null;
    if (sid == null) return;
    final client = httpClient ?? http.Client();
    try {
      await client
          .delete(
            Uri.parse(baseUrl),
            headers: {...headers, 'mcp-session-id': sid},
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Terminasi session bersifat best-effort.
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<Map<String, dynamic>> _send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final id = _nextId++;
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final messages = await _post(body);
    Map<String, dynamic>? match;
    for (final message in messages) {
      if (message['id'] == id) match = message;
    }
    if (match == null) {
      throw StateError('MCP HTTP response missing id $id for $method');
    }
    if (match.containsKey('error')) {
      throw StateError('MCP RPC error: ${jsonEncode(match['error'])}');
    }
    final result = match['result'];
    if (result is Map<String, dynamic>) return result;
    if (result == null) return const {};
    throw const FormatException('invalid MCP result object');
  }

  Future<void> _sendNotification(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    await _post(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  Future<List<Map<String, dynamic>>> _post(Map<String, dynamic> body) async {
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse(baseUrl),
            headers: _requestHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final sid = res.headers['mcp-session-id'];
      if (sid != null && sid.isNotEmpty) _sessionId = sid;
      if (res.statusCode >= 400) {
        throw StateError('MCP HTTP ${res.statusCode}: ${res.body}');
      }
      final contentType = res.headers['content-type'] ?? '';
      final text = res.body.trim();
      final List<Map<String, dynamic>> messages;
      if (contentType.contains('text/event-stream') ||
          text.startsWith('data:')) {
        messages = _messagesFromSse(text);
      } else if (text.isEmpty) {
        messages = const [];
      } else {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          messages = [decoded];
        } else if (decoded is List) {
          final out = <Map<String, dynamic>>[];
          for (final item in decoded) {
            if (item is! Map) {
              throw const FormatException('invalid MCP batch response');
            }
            out.add(Map<String, dynamic>.from(item));
          }
          messages = out;
        } else {
          throw const FormatException('invalid MCP HTTP response body');
        }
      }
      final withId = <Map<String, dynamic>>[];
      for (final message in messages) {
        if (message['id'] == null) {
          notifications.add(message);
        } else {
          withId.add(message);
        }
      }
      return withId;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  List<Map<String, dynamic>> _messagesFromSse(String text) {
    final out = <Map<String, dynamic>>[];
    for (final block in text.split(RegExp(r'\r?\n\r?\n'))) {
      final data = StringBuffer();
      for (final line in block.split(RegExp(r'\r?\n'))) {
        if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
          data.write('\n');
        }
      }
      final payload = data.toString().trim();
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } catch (_) {
        // Blok SSE rusak dilewati; respons dengan id cocok yang diutamakan.
      }
    }
    return out;
  }

  Map<String, String> _requestHeaders() => {
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        if (_sessionId != null) 'mcp-session-id': _sessionId!,
        ...headers,
      };
}
