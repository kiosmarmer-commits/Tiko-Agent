import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';

import '../sandbox.dart';
import 'transport.dart';

/// Minimal client contract shared by stdio and HTTP MCP clients so the
/// loader and proxy tool can be transport-agnostic.
abstract class McpToolServer {
  Future<void> start();
  Future<List<McpToolInfo>> listTools();
  Future<String> callTool(String name, Map<String, dynamic> arguments);
  Future<void> close();
}

/// MCP JSON-RPC client over stdio. Child processes must run in an OS sandbox;
/// only tests may explicitly opt into unsandboxed fixture processes.
class StdioMcpClient implements McpTransport, McpToolServer {
  StdioMcpClient({
    required this.command,
    this.args = const [],
    this.environment,
    this.workingDirectory,
    this.protocolVersion = '2025-11-25',
    this.preferredModernProtocolVersion = '2026-07-28',
    this.sandbox,
    this.allowUnsandboxedForTesting = false,
    this.maxMessageBytes = 1024 * 1024,
  });

  final String command;
  final List<String> args;
  final Map<String, String>? environment;
  final String? workingDirectory;
  /// Protocol version offered during the legacy initialize handshake.
  final String protocolVersion;
  /// Preferred stateless protocol version used by server/discover.
  final String preferredModernProtocolVersion;
  final SandboxRunner? sandbox;
  final bool allowUnsandboxedForTesting;
  final int maxMessageBytes;

  Process? _proc;
  final _pending = <Object, Completer<Map<String, dynamic>>>{};
  final _buf = <int>[];
  int _nextId = 1;
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _started = false;
  bool _closed = false;
  bool _modernProtocol = false;
  bool _negotiated = false;
  Object? _terminalError;
  String? serverName;
  Set<String> allowedTools = const {};

  @override
  Future<void> start() async {
    if (_started) return;
    if (_closed) throw StateError('MCP client is closed');
    if (command.trim().isEmpty || command.contains('\u0000') ||
        args.length > 32 || args.any((arg) => arg.contains('\u0000'))) {
      throw ArgumentError('invalid MCP process command');
    }

    final runner = sandbox;
    if (runner == null || runner.kind == SandboxKind.none) {
      if (!allowUnsandboxedForTesting) {
        throw UnsupportedError('MCP server disabled: OS sandbox unavailable');
      }
      _proc = await Process.start(
        command,
        args,
        workingDirectory: workingDirectory,
        environment: {
          'PATH': '/usr/local/bin:/usr/bin:/bin',
          'LANG': 'C.UTF-8',
          ...?environment,
        },
        includeParentEnvironment: false,
        runInShell: false,
      );
    } else {
      _proc = await runner.startProcess(
        [command, ...args],
        workingDirectory: workingDirectory,
        environment: environment,
      );
    }

    _sub = _proc!.stdout.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        _terminalError = error;
        _started = false;
        _failPending(error);
      },
      onDone: () {
        if (!_closed) {
          _terminalError = StateError('MCP server stdout closed');
          _started = false;
          _failPending(_terminalError!);
        }
      },
      cancelOnError: true,
    );
    _stderrSub = _proc!.stderr.listen((_) {}, onError: (_) {});
    _started = true;
    unawaited(_proc!.exitCode.then((code) {
      if (!_closed) {
        _terminalError = StateError('MCP server exited with code $code');
        _started = false;
        _failPending(_terminalError!);
      }
    }));

    await _negotiateProtocol();
  }

  /// List tools exposed by the server. Names and schemas are untrusted config
  /// inputs; malformed entries abort loading instead of being partially used.
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
      if (name is! String || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$').hasMatch(name)) {
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
        inputSchema: schema is Map ? Map<String, dynamic>.from(schema) : const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
      );
    }).toList(growable: false);
  }

  /// Call only an explicitly allowlisted server tool. Output is untrusted.
  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    if (!allowedTools.contains(name)) {
      throw StateError('MCP tool is not allowlisted: $name');
    }
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
          if (totalChars > 100000) throw const FormatException('MCP output too large');
          texts.add(text);
        }
      } else {
        final encoded = jsonEncode(item);
        totalChars += encoded.length;
        if (totalChars > 100000) throw const FormatException('MCP output too large');
        texts.add(encoded);
      }
    }
    final body = texts.join('\n');
    if (res['isError'] == true) return 'MCP error: $body';
    final safeSource = (serverName ?? 'server').replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final safeBody = body
        .replaceAll('</untrusted_data', '<\\/untrusted_data')
        .replaceAll('<untrusted_data', '<\\untrusted_data');
    return '<untrusted_data source="mcp:$safeSource">\n$safeBody\n</untrusted_data>';
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    await _ensureStarted();
    return _sendRpc(
      method,
      params,
      includeMeta: _modernProtocol,
      timeout: const Duration(seconds: 30),
    );
  }

  Future<Map<String, dynamic>> _sendRpc(
    String method,
    Map<String, dynamic>? params, {
    required bool includeMeta,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_pending.length >= 128) {
      throw StateError('too many concurrent MCP requests');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final requestParams = <String, dynamic>{...?params};
    if (includeMeta) {
      requestParams['_meta'] = _requestMeta();
    }
    final message = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null || includeMeta) 'params': requestParams,
    };
    try {
      _write(message);
    } catch (error) {
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(error);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('MCP request timeout: $method');
      },
    );
  }

  Map<String, dynamic> _requestMeta() => {
    'io.modelcontextprotocol/protocolVersion': preferredModernProtocolVersion,
    'io.modelcontextprotocol/clientInfo': {
      'name': 'tiko',
      'version': '0.1.0',
    },
    'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
  };

  Future<void> _negotiateProtocol() async {
    if (_negotiated) return;
    _negotiated = true;
    try {
      final discovered = await _sendRpc(
        'server/discover',
        null,
        includeMeta: true,
        timeout: const Duration(seconds: 4),
      );
      final versions = discovered['supportedVersions'];
      if (versions is! List || versions.any((v) => v is! String)) {
        throw const FormatException('invalid MCP server/discover result');
      }
      if (!versions.contains(preferredModernProtocolVersion)) {
        throw UnsupportedError(
          'MCP server supports ${versions.join(', ')}, but Tiko requires '
          '$preferredModernProtocolVersion for stateless mode.',
        );
      }
      _modernProtocol = true;
      final meta = discovered['_meta'];
      if (meta is Map) {
        final info = meta['io.modelcontextprotocol/serverInfo'];
        if (info is Map && info['name'] is String) {
          serverName = info['name'] as String;
        }
      }
      return;
    } on _McpRpcException catch (error) {
      if (error.code == -32022) {
        final supported = error.data?['supported'];
        if (supported is List && supported.contains(preferredModernProtocolVersion)) {
          _modernProtocol = true;
          return;
        }
        throw UnsupportedError(
          'MCP server rejected $preferredModernProtocolVersion; '
          'supported versions: ${supported is List ? supported.join(', ') : 'not advertised'}.',
        );
      }
      // Per MCP stdio backward compatibility, every other JSON-RPC error
      // identifies a legacy handshake-based server.
    } on TimeoutException {
      // Legacy implementations commonly ignore the pre-initialize probe.
    }

    final init = await _sendRpc('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': {'tools': {}},
      'clientInfo': {'name': 'tiko', 'version': '0.1.0'},
    }, includeMeta: false);
    serverName = (init['serverInfo'] as Map?)?['name'] as String?;
    _modernProtocol = false;
    await notify('notifications/initialized');
  }

  Future<void> _ensureStarted() async {
    if (_terminalError != null) throw StateError('MCP server terminated: $_terminalError');
    if (!_started) await start();
    if (_terminalError != null) throw StateError('MCP server terminated: $_terminalError');
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    await _ensureStarted();
    final notificationParams = <String, dynamic>{...?params};
    if (_modernProtocol) notificationParams['_meta'] = _requestMeta();
    _write({
      'jsonrpc': '2.0',
      'method': method,
      if (params != null || _modernProtocol) 'params': notificationParams,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    await _stderrSub?.cancel();
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      final runner = sandbox;
      if (runner != null && runner.kind != SandboxKind.none) {
        await runner.stopProcess(proc);
      } else {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    _started = false;
    _failPending(StateError('MCP client closed'));
  }

  void _write(Map<String, dynamic> message) {
    final process = _proc;
    if (process == null || _closed) throw StateError('MCP process unavailable');
    final body = utf8.encode(jsonEncode(message));
    if (body.length > maxMessageBytes) throw ArgumentError('MCP request too large');
    // MCP stdio uses one JSON-RPC message per line (UTF-8 JSONL).
    process.stdin.add([...body, 10]);
  }

  void _onData(List<int> chunk) {
    _buf.addAll(chunk);
    while (_buf.isNotEmpty) {
      // Read legacy Content-Length framed responses for compatibility with
      // older non-standard servers, while sending standard JSONL requests.
      if (_looksLikeContentLengthPrefix()) {
        if (_buf.length < 'Content-Length:'.length) return;
        if (!_readContentLengthMessage()) return;
        continue;
      }
      final newline = _buf.indexOf(10);
      if (newline < 0) {
        if (_buf.length > maxMessageBytes) {
          _failPending(const FormatException('MCP JSONL message too large'));
          _killProcess();
        }
        return;
      }
      var end = newline;
      if (end > 0 && _buf[end - 1] == 13) end--;
      final bytes = _buf.sublist(0, end);
      _buf.removeRange(0, newline + 1);
      if (bytes.isEmpty) continue;
      if (bytes.length > maxMessageBytes) {
        _failPending(const FormatException('MCP JSONL message too large'));
        _killProcess();
        return;
      }
      _decodeMessage(bytes);
      if (_terminalError != null) return;
    }
  }

  bool _looksLikeContentLengthPrefix() {
    const prefix = 'Content-Length:';
    final count = _buf.length < prefix.length ? _buf.length : prefix.length;
    for (var i = 0; i < count; i++) {
      final actual = _buf[i] >= 65 && _buf[i] <= 90 ? _buf[i] + 32 : _buf[i];
      final expected = prefix.codeUnitAt(i) >= 65 && prefix.codeUnitAt(i) <= 90
          ? prefix.codeUnitAt(i) + 32
          : prefix.codeUnitAt(i);
      if (actual != expected) return false;
    }
    return true;
  }

  bool _readContentLengthMessage() {
    final headerEnd = _indexOfHeaderEnd(_buf);
    if (headerEnd < 0) {
      if (_buf.length > 8192) {
        _failPending(const FormatException('MCP header too large'));
        _killProcess();
      }
      return false;
    }
    final String header;
    try {
      header = utf8.decode(_buf.sublist(0, headerEnd), allowMalformed: false);
    } catch (error) {
      _failPending(FormatException('MCP response header is not UTF-8: $error'));
      _killProcess();
      return false;
    }
    final lengthHeaders = header.split('\r\n').where((line) =>
        RegExp(r'^Content-Length:\s*\d+\s*$', caseSensitive: false).hasMatch(line.trim())).toList();
    final match = lengthHeaders.length == 1
        ? RegExp(r'^Content-Length:\s*(\d+)\s*$', caseSensitive: false)
            .firstMatch(lengthHeaders.single.trim())
        : null;
    if (match == null) {
      _failPending(const FormatException('MCP response has invalid Content-Length'));
      _killProcess();
      return false;
    }
    final length = int.tryParse(match.group(1)!);
    if (length == null || length < 0 || length > maxMessageBytes) {
      _failPending(const FormatException('MCP response length is invalid'));
      _killProcess();
      return false;
    }
    final bodyStart = headerEnd + 4;
    if (_buf.length < bodyStart + length) return false;
    final bodyBytes = _buf.sublist(bodyStart, bodyStart + length);
    _buf.removeRange(0, bodyStart + length);
    _decodeMessage(bodyBytes);
    return true;
  }

  void _decodeMessage(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('MCP JSON-RPC response must be an object');
      }
      _handleMessage(decoded);
    } catch (error) {
      _terminalError = error;
      _failPending(error);
      _killProcess();
    }
  }

  int _indexOfHeaderEnd(List<int> buffer) {
    for (var i = 0; i + 3 < buffer.length; i++) {
      if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _handleMessage(Map<String, dynamic> json) {
    final id = json['id'];
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (json.containsKey('error')) {
      final rawError = json['error'];
      if (rawError is Map) {
        completer.completeError(_McpRpcException(
          code: rawError['code'] is int ? rawError['code'] as int : null,
          message: rawError['message'] is String ? rawError['message'] as String : 'MCP RPC error',
          data: rawError['data'] is Map
              ? Map<String, dynamic>.from(rawError['data'] as Map)
              : null,
        ));
      } else {
        completer.completeError(FormatException('invalid MCP RPC error: $rawError'));
      }
    } else {
      final result = json['result'];
      if (result is Map<String, dynamic>) {
        completer.complete(result);
      } else {
        completer.completeError(const FormatException('invalid MCP result object'));
      }
    }
  }

  void _killProcess() {
    final process = _proc;
    if (process == null) return;
    final runner = sandbox;
    if (runner != null && runner.kind != SandboxKind.none) {
      unawaited(runner.stopProcess(process));
    } else {
      process.kill(ProcessSignal.sigkill);
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

class _McpRpcException implements Exception {
  const _McpRpcException({required this.code, required this.message, this.data});

  final int? code;
  final String message;
  final Map<String, dynamic>? data;

  @override
  String toString() => 'MCP RPC error ${code ?? ''}: $message';
}

class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

/// Adapter for an allowlisted MCP tool; namespaced per server to avoid clash.
class McpProxyTool implements Tool {
  McpProxyTool({
    required this.client,
    required this.info,
    required this.serverId,
    this.risk = 'high',
  });

  final McpToolServer client;
  final McpToolInfo info;
  final String serverId;
  final String risk;

  @override
  ToolSpec get spec => ToolSpec(
    name: 'mcp_${serverId}_${info.name}',
    description: '[MCP:$serverId] ${info.description}',
    inputSchema: info.inputSchema,
    risk: risk,
    timeoutSec: 45,
  );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final output = await client.callTool(info.name, args);
      return ToolResult(callId: '', content: output);
    } catch (error) {
      return ToolResult(callId: '', content: 'MCP call failed: $error', isError: true);
    }
  }
}
