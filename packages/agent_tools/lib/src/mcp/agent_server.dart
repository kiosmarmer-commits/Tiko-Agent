import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Hasil satu pemanggilan tool di sisi server MCP.
class McpToolResult {
  const McpToolResult({required this.text, this.isError = false});

  final String text;
  final bool isError;
}

/// Satu tool yang diekspos server MCP ke klien (AI agent lain).
class McpAgentTool {
  const McpAgentTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<McpToolResult> Function(Map<String, dynamic> arguments) handler;
}

/// Model Context Protocol (MCP) server side — JSON-RPC 2.0 newline-delimited
/// stdio, kebalikan dari MCP client yang sudah ada di `src/mcp/*_client.dart`.
///
/// AI agent lain (Claude Desktop, Hermes, keduanya via klien MCP) menjalankan
/// `tiko mcp` sebagai subprocess dan mengendalikan Tiko sepenuhnya: chat
/// ReAct penuh dengan seluruh tool + gate approval, daftar tool internal,
/// daftar sesi, dan status runtime.
///
/// Method yang didukung:
/// - `initialize` → protocolVersion (echo dari klien bila valid) +
///   capabilities `{tools: {}}` + serverInfo `{name, version}`.
/// - `notifications/initialized`, `notifications/cancelled` → diabaikan
///   (tanpa respons).
/// - `tools/list` → daftar [McpAgentTool].
/// - `tools/call {name, arguments}` → handler tool; kegagalan handler
///   menjadi result `isError: true` (fail-closed, server tetap hidup).
/// - `ping` → result `{}`.
///
/// Log apa pun harus ke stderr — stdout murni untuk framing JSON-RPC.
class McpAgent {
  McpAgent({
    required this.serverName,
    required this.serverVersion,
    required this.tools,
    Stream<String>? input,
    void Function(String line)? output,
  })  : _input = input ??
            // stdin must be line-delimited: utf8.decoder alone emits decoded
            // chunks (possibly several JSON messages at once), so a
            // LineSplitter is required for real stdio pipes.
            stdin.transform(utf8.decoder).transform(const LineSplitter()),
        _output = output ?? ((line) => stdout.writeln(line));

  static const _defaultProtocolVersion = '2024-11-05';
  static const _supportedProtocolVersions = {
    '2024-11-05',
    '2025-03-26',
    '2025-06-18',
  };

  final String serverName;
  final String serverVersion;
  final List<McpAgentTool> tools;
  final Stream<String> _input;
  final void Function(String line) _output;

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
    } catch (_) {} // best-effort
    if (message == null) {
      _output(jsonEncode(_error(null, -32700, 'Parse error: JSON tidak valid')));
      return;
    }
    unawaited(_dispatch(message));
  }

  Future<void> _dispatch(Map<String, dynamic> message) async {
    final method = message['method'] as String?;
    final id = message['id'];
    final params = message['params'];
    if (method == null) {
      _output(jsonEncode(_error(id, -32600, 'Invalid Request: method hilang')));
      return;
    }
    // Notification: tanpa field `id` — tidak boleh dibalas.
    if (id == null) {
      switch (method) {
        case 'notifications/initialized':
        case 'notifications/cancelled':
          return;
        default:
          return;
      }
    }
    switch (method) {
      case 'initialize':
        final map = params is Map<String, dynamic> ? params : const {};
        final requested = map['protocolVersion'];
        _output(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': requested is String &&
                    _supportedProtocolVersions.contains(requested)
                ? requested
                : _defaultProtocolVersion,
            'capabilities': {
              'tools': {'listChanged': false},
            },
            'serverInfo': {
              'name': serverName,
              'version': serverVersion,
            },
          },
        }));
        return;
      case 'ping':
        _output(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {}}));
        return;
      case 'tools/list':
        _output(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              for (final tool in tools)
                {
                  'name': tool.name,
                  'description': tool.description,
                  'inputSchema': tool.inputSchema,
                },
            ],
          },
        }));
        return;
      case 'tools/call':
        _output(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': await _callTool(params)}));
        return;
      default:
        _output(jsonEncode(_error(id, -32601, 'Method not found: $method')));
        return;
    }
  }

  Future<Map<String, dynamic>> _callTool(dynamic params) async {
    final map = params is Map<String, dynamic> ? params : const {};
    final name = map['name'] as String?;
    final tool = name == null ? null : _tool(name);
    if (tool == null) {
      return _toolResult(
        'Tool tidak dikenal: ${name ?? '<kosong>'}. '
        'Gunakan tools/list untuk melihat daftar tool yang tersedia.',
        isError: true,
      );
    }
    final rawArgs = map['arguments'] ?? const {};
    final args = rawArgs is Map<String, dynamic>
        ? rawArgs
        : Map<String, dynamic>.from(rawArgs as Map);
    try {
      final result = await tool.handler(args);
      return _toolResult(result.text, isError: result.isError);
    } catch (e) {
      return _toolResult('Tool $name gagal: $e', isError: true);
    }
  }

  McpAgentTool? _tool(String name) {
    for (final tool in tools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  Map<String, dynamic> _toolResult(String text, {required bool isError}) => {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'isError': isError,
      };

  Map<String, dynamic> _error(dynamic id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}
