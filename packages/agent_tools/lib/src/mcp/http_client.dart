import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'transport.dart';
import 'stdio_client.dart' show McpToolInfo, McpToolServer;

/// MCP client over Streamable HTTP / JSON-RPC POST (spec-oriented, best-effort).
///
/// Many servers accept:
///   POST {baseUrl}  with JSON-RPC body
/// or
///   POST {baseUrl}/message
class HttpMcpClient implements McpTransport, McpToolServer {
  HttpMcpClient({
    required this.baseUrl,
    this.headers = const {},
    this.httpClient,
    this.protocolVersion = '2025-11-25',
  });

  final String baseUrl;
  final Map<String, String> headers;
  final http.Client? httpClient;
  final String protocolVersion;

  int _nextId = 1;
  bool _started = false;
  String? serverName;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final init = await request('initialize', {
        'protocolVersion': protocolVersion,
        'capabilities': {'tools': {}},
        'clientInfo': {'name': 'agent_dart', 'version': '0.1.0'},
      });
      serverName = (init['serverInfo'] as Map?)?['name'] as String?;
      await notify('notifications/initialized');
    } catch (_) {}
  }

  @override
  Future<List<McpToolInfo>> listTools() async {
    final res = await request('tools/list');
    final tools = (res['tools'] as List<dynamic>? ?? []);
    return tools.map((t) {
      final m = t as Map<String, dynamic>;
      return McpToolInfo(
        name: m['name'] as String,
        description: m['description'] as String? ?? '',
        inputSchema:
            (m['inputSchema'] as Map<String, dynamic>?) ??
            {'type': 'object', 'properties': {}},
      );
    }).toList();
  }

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final res = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final content = res['content'] as List<dynamic>?;
    if (content == null) return jsonEncode(res);
    final texts = <String>[];
    for (final c in content) {
      final m = c as Map<String, dynamic>;
      if (m['type'] == 'text') {
        texts.add(m['text'] as String? ?? '');
      } else {
        texts.add(jsonEncode(m));
      }
    }
    final body = texts.join('\n');
    if (res['isError'] == true) return 'MCP error: $body';
    return '<untrusted_data source="mcp-http:${serverName ?? 'server'}">\n$body\n</untrusted_data>';
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    await start();
    final id = _nextId++;
    final msg = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final client = httpClient ?? http.Client();
    try {
      final res = await client
          .post(
            Uri.parse(baseUrl),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              ...headers,
            },
            body: jsonEncode(msg),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw StateError('MCP HTTP ${res.statusCode}: ${res.body}');
      }
      final body = res.body.trim();
      // Handle single JSON or simple SSE data line
      Map<String, dynamic> json;
      if (body.startsWith('data:')) {
        final line = body
            .split('\n')
            .firstWhere((l) => l.startsWith('data:'), orElse: () => 'data: {}');
        json = jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
      } else {
        json = jsonDecode(body) as Map<String, dynamic>;
      }
      if (json.containsKey('error')) {
        throw StateError(jsonEncode(json['error']));
      }
      return (json['result'] as Map<String, dynamic>?) ?? {};
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    await start();
    final client = httpClient ?? http.Client();
    try {
      await client.post(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json', ...headers},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': method,
          if (params != null) 'params': params,
        }),
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  @override
  Future<void> close() async {
    _started = false;
  }
}
